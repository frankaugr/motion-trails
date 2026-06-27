import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Orchestrates the offline trail render (spec §11). Reads source frames, builds a motion mask
/// against the background (minus any ignore regions), composites with persistent replacement or
/// overlay, maintains a per-pixel **age map** that drives trail fade and age-gradient color, then
/// crops/scales and encodes each accumulated state to an MP4.
///
/// `render` is async and cancellable; it reports fractional progress as frames are written.
/// Processing runs at the full oriented resolution; crop and the 4K cap are applied last
/// (spec §11.1, §8).
struct TrailRenderEngine {

    enum Output {
        case trail
        case mask
    }

    /// Coarse phase of a render, for UI that wants a stage label alongside the fraction.
    enum RenderStage: Sendable {
        /// Sampling the clip for the background plate (before any output frame exists).
        case analyzing
        /// Writing output frames.
        case rendering
    }

    /// Fraction of the progress range reserved for the analyzing pre-pass.
    private static let analyzingShare = 0.1

    /// Long-edge cap for the mask working space: detection runs on frames downscaled to this size
    /// and the finished mask is upscaled back to full resolution (see the note in `render`).
    private static let maskWorkingEdge: CGFloat = 960

    /// Handheld-parallax size measure, in mask-working-space px: σ of the Gaussian that turns a
    /// frame's motion mask into a per-pixel "local blob size" signal (blurred coverage ≈ the
    /// fraction of the σ-neighbourhood the blob fills, so the value rises with blob size), and
    /// the radius of the dilate that spreads each blob's peak over its whole footprint — feather
    /// rim included — so a mark classifies as one unit instead of leaving per-pixel seams.
    private static let parallaxSizeSigma: Float = 10
    /// Depth bands for handheld parallax, ordered far → near (also compositing order). A mark
    /// rides the plane of the highest band whose `cutoff` its size signal clears; below the first
    /// cutoff it stays on the base scene plane. The handheld pose then translates each plane
    /// `push × base offset` further than the scene. With σ = 10 a disc of radius r peaks at
    /// ≈ 1 − exp(−r² / 2σ²), so these cutoffs put the band boundaries at r ≈ 5 / 7.5 / 10 / 12.5
    /// working px. Pushes stay under the base offset: the *differential* is what sells depth, and
    /// much past half the base offset a plane reads as sliding off its scene anchor instead of
    /// swaying with it. Four bands (five depth layers with the base scene) is the deliberate
    /// ceiling: each band costs 2–3 persistent full-res GPU buffers plus per-frame compositing
    /// (and a per-frame flatten each when fade/gradient are on), while slicing the capped push
    /// range any finer drops adjacent-plane differentials below ~2 px at 1080p — invisible.
    private static let parallaxBands: [(cutoff: Float, push: Double)] = [
        (0.12, 0.15),
        (0.25, 0.30),
        (0.40, 0.45),
        (0.55, 0.60),
    ]

    func render(
        sourceURL: URL,
        settings: RenderSettings,
        output: Output = .trail,
        maxOutputDimension: CGFloat = .greatestFiniteMagnitude,
        progress: (@Sendable (Double) -> Void)? = nil,
        stage: (@Sendable (RenderStage) -> Void)? = nil
    ) async throws -> URL {
        let reader = try await VideoFrameReader(url: sourceURL)
        let info = reader.info
        let fullSize = info.orientedSize
        let fullRect = CGRect(origin: .zero, size: fullSize)

        // Mask working space (§11.4): detection runs on a downscaled copy of each frame (long edge
        // capped at `Self.maskWorkingEdge`) and the finished mask is bilinearly upscaled back to
        // full resolution for compositing. Full-resolution masking amputated thin structure — the
        // morphology open's 2 px erode deletes any feature thinner than ~5 px, so a distant bird's
        // wings vanished and the re-dilated body core rendered as a round blob, while the
        // proxy-based live preview kept the shape. Thresholding the downscale-averaged signal
        // instead (with the morphology radii scaled to match, like the preview) preserves those
        // features, pre-averages sensor/H.264 noise out of the threshold input, and makes the
        // mask pass much cheaper at 4K. The upscale doubles as a soft feather.
        let maskDownscale = min(1, Self.maskWorkingEdge / max(fullSize.width, fullSize.height))
        let maskSize = CGSize(width: max(2, Int((fullSize.width * maskDownscale).rounded()) & ~1),
                              height: max(2, Int((fullSize.height * maskDownscale).rounded()) & ~1))
        let maskRect = CGRect(origin: .zero, size: maskSize)
        let maskScaleX = maskSize.width / fullSize.width
        let maskScaleY = maskSize.height / fullSize.height
        let masksDownscaled = maskDownscale < 1

        // Social crop (after processing, §11.1), then the 4K downscale (§8, §16).
        let cropRect = settings.cropAspect.cropRect(in: fullSize)
        let outputSize = scaledOutputSize(cropRect.size, maxDimension: maxOutputDimension)
        let outputRect = CGRect(origin: .zero, size: outputSize)
        let exportScale = outputSize.width / cropRect.size.width

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("trail-\(UUID().uuidString).mp4")
        // Only a completed render hands `outputURL` back to the caller; on a throw or cancellation
        // nobody else can reclaim the partial temp file, so drop it here.
        var renderSucceeded = false
        defer { if !renderSucceeded { try? FileManager.default.removeItem(at: outputURL) } }
        let writer = try VideoFrameWriter(outputURL: outputURL, size: outputSize, frameRate: settings.outputFPS)

        try reader.start()
        try writer.start()

        let context = SharedRender.ciContext
        let workingColorSpace = context.workingColorSpace ?? CGColorSpaceCreateDeviceRGB()
        let flattener = PixelBufferFlattener(size: fullSize, colorSpace: workingColorSpace)
        // Independent pool for the ±K look-ahead ring buffer: each decoded frame is rendered into its
        // own GPU buffer so it survives across loop iterations (the reader vends recycled sample
        // buffers) without contending with the accumulator's flatten pool.
        let frameFlattener = PixelBufferFlattener(size: fullSize, colorSpace: workingColorSpace)
        // Small dedicated pool for the mask-resolution proxy the window keeps per frame.
        let maskFlattener = masksDownscaled
            ? PixelBufferFlattener(size: maskSize, colorSpace: workingColorSpace) : nil
        let maskBuilder = MotionMaskBuilder()
        let compositor = TrailCompositor()
        let colorizer = settings.colorStyle == .ageGradient
            ? TrailColorizer(oldest: settings.gradientOldest.ciColor, newest: settings.gradientNewest.ciColor)
            : nil
        let keepMask = IgnoreMaskBuilder.keepMask(regions: settings.ignoreRegions,
                                                  strokes: settings.ignoreStrokes, size: fullSize)

        // Static background = temporal median across the clip (spec §11.2). It is **not** the detection
        // reference any more (detection is temporal); it is the clean display **plate** the trails
        // composite over, and the seed for the accumulator. Its sampling is surfaced as the
        // "analyzing" slice of the progress range so the bar moves from the very start.
        stage?(.analyzing)
        let staticBackground = try await BackgroundEstimator().estimate(url: sourceURL, cropRect: fullRect) { fraction in
            progress?(fraction * Self.analyzingShare)
        }
        stage?(.rendering)
        let decay = settings.ageDecay
        let colorDecay = settings.gradientDecay
        // Display backdrop: trails composite over the frozen plate, or over the live current frame.
        let liveBackdrop = settings.backgroundMode == .live
        // Simulated handheld motion re-projects the *final* composited frame (display only —
        // detection runs on the untouched tripod frames), before the crop. Sampled at output
        // time, deterministic across re-renders.
        let handheld = settings.handheldAmount > 0 ? HandheldMotion(intensity: settings.handheldAmount) : nil
        // Depth parallax: large (≈ nearer) marks are accumulated on their own transparent plane,
        // which the handheld pose translates slightly more than the scene (see HandheldMotion).
        let parallaxOn = handheld != nil && settings.handheldParallax
        let outputFPS = Double(settings.outputFPS)

        // Detection horizon K (frames): each frame is differenced against the frames ±K away. Slow
        // drift (clouds, swaying foliage) is unchanged over ±K and cancels; fast subjects survive.
        let horizon = settings.motionHorizonFrames(fps: Double(info.nominalFrameRate))
        let darkLumaCutoff = 0.06

        let registrar = settings.stabilizationEnabled ? FrameRegistrar(reference: staticBackground) : nil

        // Trail frequency → how many evenly-spaced snapshots leave a *persistent* silhouette in
        // the trail. The live subject is still drawn on top of every frame, so motion stays smooth
        // regardless of frequency; only the permanence of the trail changes.
        let snapshotCount = settings.snapshotCount(durationSeconds: info.duration.seconds)

        let total = max(1, info.estimatedFrameCount)
        var written = 0
        var processedIndex = 0
        var sawBright = false
        var accumulator = staticBackground   // persistent trail (subject colors)
        var ageMap = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: fullRect)  // persistent recency
        // Colour recency for the age gradient — decays at the gradient-speed rate, independently of
        // `ageMap` (the fade), so the hue sweeps even on a fully persistent trail.
        var colorAgeMap = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: fullRect)
        // Near depth planes for handheld parallax (empty unless `parallaxOn`): each size band's
        // marks accumulate over *transparency*, with their own age/colour maps, so the planes
        // behind keep smaller marks alive underneath them — when a nearer plane sways aside,
        // what's behind is genuinely revealed rather than filled with backdrop. Ordered far →
        // near (ascending push), which is also the compositing order.
        struct TrailPlane {
            var accumulator: CIImage
            var ageMap: CIImage
            var colorAgeMap: CIImage
            let push: Double
        }
        var nearPlanes: [TrailPlane] = !parallaxOn ? [] : Self.parallaxBands.map { band in
            TrailPlane(accumulator: CIImage(color: .clear).cropped(to: fullRect),
                       ageMap: CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: fullRect),
                       colorAgeMap: CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: fullRect),
                       push: band.push)
        }

        // Seed the output with the clean background as frame 0 (shaken too, so the handheld pose
        // is continuous from the very first frame).
        if output == .trail {
            let seedBuffer = try autoreleasepool {
                let seed = handheld?.apply(to: staticBackground, at: 0, frameRect: fullRect) ?? staticBackground
                return try writer.makeFrameBuffer(
                    prepareExport(seed, cropRect: cropRect, scale: exportScale,
                                  outputRect: outputRect),
                    context: context)
            }
            try await writer.append(seedBuffer)
        }

        // Delay-line over the decoded stream so each processed "centre" frame has its ±K neighbours
        // available. Neighbours are only ever consumed by the mask, so the window keeps a small
        // mask-resolution proxy for the whole ±K span and the full-resolution frame only until its
        // own centre pass (released in `emit`): at most ~K+1 full-res frames plus 2K+1 proxies are
        // resident, bounded regardless of clip length, so the long-clip memory invariant holds.
        // Each frame stores whether it's bright, so a dark fade neighbour can be skipped rather
        // than flooding the temporal difference.
        struct WindowFrame {
            var image: CIImage?     // full-res; released once this frame's centre pass has run
            let proxy: CIImage      // mask-resolution copy — all a ±K neighbour ever needs
            let bright: Bool
        }
        var window: [WindowFrame] = []
        var firstIndex = 0          // global index of window[0]
        var nextToProcess = 0       // global index of the next centre to emit

        // Build the output buffer for centre frame `centre` (nil = skip a leading dark fade-in). The
        // heavy Core Image work runs in an autoreleasepool so transient Metal textures/IOSurfaces are
        // reclaimed every frame; the encode-side `append` is awaited *outside* the pool by `emit`.
        func renderCentre(_ centre: Int) throws -> CVPixelBuffer? {
            try autoreleasepool {
                let rec = window[centre - firstIndex]
                if !sawBright {
                    if !rec.bright { return nil }   // skip leading black fade-in
                    sawBright = true
                }
                defer { processedIndex += 1 }
                // ~`snapshotCount` evenly-spaced frames leave a permanent mark.
                let isSnapshot = processedIndex == 0 ||
                    Int(Double(processedIndex) * Double(snapshotCount) / Double(total)) >
                    Int(Double(processedIndex - 1) * Double(snapshotCount) / Double(total))

                // ±K neighbours (mask-resolution proxies). A neighbour that is out of the clip or a
                // dark fade frame shrinks the horizon instead of vanishing: scan *inward* from ±K
                // for the nearest bright frame. The resulting pair is then used both-or-nothing —
                // a one-sided difference resurrects the trailing "ghost" the symmetric min exists
                // to remove (near the clip's ends it stamped sky-coloured bird shapes over the
                // trail marks the subject had left ±K frames before). A shrunken horizon still
                // cancels the ghost and merely detects less as the offset approaches 0, so the
                // trail degrades gracefully into the first/last frames instead of corrupting them.
                func temporalReference(_ step: Int) -> CIImage? {
                    var gi = centre + step * horizon
                    while gi != centre {
                        if gi >= firstIndex, gi - firstIndex < window.count {
                            let n = window[gi - firstIndex]
                            if n.bright { return n.proxy }
                        }
                        gi -= step
                    }
                    return nil
                }
                let earlier = temporalReference(-1)
                let later = temporalReference(+1)
                let bothSides = earlier != nil && later != nil
                // Full-res frames are released only after their centre pass, so this one is present.
                let current = rec.image!  // already oriented, registered and flattened at decode time
                // Detect in the mask working space, then upscale the mask to the compositing space.
                let proxyMask = maskBuilder.makeMask(current: rec.proxy,
                                                     earlier: bothSides ? earlier : nil,
                                                     later: bothSides ? later : nil,
                                                     settings: settings, radiusScale: maskScaleX)
                let rawMask = masksDownscaled
                    ? proxyMask.clampedToExtent()
                        .transformed(by: CGAffineTransform(scaleX: 1 / maskScaleX, y: 1 / maskScaleY))
                        .cropped(to: fullRect)
                    : proxyMask
                var coverage = alphaToGray(rawMask, rect: fullRect)
                if let keepMask { coverage = multiply(coverage, keepMask, rect: fullRect) }
                let mask = maskToAlpha(coverage)

                let exportFrame: CIImage
                switch output {
                case .trail:
                    // Fade the persistent trail every frame for smooth decay.
                    if decay < 1 {
                        ageMap = flattener.flatten(scaleGray(ageMap, decay), rect: fullRect, context: context)
                        for i in nearPlanes.indices {
                            nearPlanes[i].ageMap = flattener.flatten(scaleGray(nearPlanes[i].ageMap, decay),
                                                                     rect: fullRect, context: context)
                        }
                    }
                    if colorizer != nil, colorDecay < 1 {
                        colorAgeMap = flattener.flatten(scaleGray(colorAgeMap, colorDecay), rect: fullRect, context: context)
                        for i in nearPlanes.indices {
                            nearPlanes[i].colorAgeMap = flattener.flatten(scaleGray(nearPlanes[i].colorAgeMap, colorDecay),
                                                                          rect: fullRect, context: context)
                        }
                    }

                    // Parallax: partition this frame's coverage into size bands, measured on the
                    // proxy mask (live subjects only — never the accumulated trail, so a dense
                    // trail of small birds still classifies as small). A mark rides the plane of
                    // the highest band whose cutoff its size signal clears; below the first
                    // cutoff it stays on the base scene plane. A mark is classified once, here,
                    // at stamp time.
                    var farCoverage = coverage
                    var bandCoverages: [CIImage] = []
                    if parallaxOn {
                        let signal = blobSizeSignal(alphaToGray(proxyMask, rect: proxyMask.extent),
                                                    rect: proxyMask.extent)
                        let fullSignal = masksDownscaled
                            ? signal.clampedToExtent()
                                .transformed(by: CGAffineTransform(scaleX: 1 / maskScaleX, y: 1 / maskScaleY))
                                .cropped(to: fullRect)
                            : signal
                        // One binary gate per cutoff; band i = gate i minus the band above it.
                        let gates = Self.parallaxBands.map { thresholdGray(fullSignal, $0.cutoff, rect: fullRect) }
                        bandCoverages = gates.indices.map { i in
                            let bandGray = i + 1 < gates.count
                                ? multiply(gates[i], invertGray(gates[i + 1], rect: fullRect), rect: fullRect)
                                : gates[i]
                            return multiply(coverage, bandGray, rect: fullRect)
                        }
                        farCoverage = multiply(coverage, invertGray(gates[0], rect: fullRect), rect: fullRect)
                    }

                    // Display = persistent trail + the current (live) subject on top → smooth motion.
                    let displayAccumulator = compositor.compose(current: current, over: accumulator,
                                                                mask: parallaxOn ? maskToAlpha(farCoverage) : mask,
                                                                mode: settings.trailMode)
                    let displayAgeMap = maximum(farCoverage, ageMap, rect: fullRect)
                    let displayColorAgeMap = colorizer != nil ? maximum(farCoverage, colorAgeMap, rect: fullRect) : displayAgeMap
                    let trailColor = colorizer?.colorize(displayColorAgeMap) ?? displayAccumulator
                    // Near planes: the same compose/age/colour steps against each plane's
                    // transparent state, restricted to its band's marks. Each layer keeps its own
                    // alpha so it can be re-projected and composited over the shaken base.
                    var planeDisplays: [(accumulator: CIImage, ageMap: CIImage, colorAgeMap: CIImage, layer: CIImage)] = []
                    for (i, plane) in nearPlanes.enumerated() {
                        let bandCoverage = bandCoverages[i]
                        let acc = compositor.compose(current: current, over: plane.accumulator,
                                                     mask: maskToAlpha(bandCoverage), mode: settings.trailMode)
                        let age = maximum(bandCoverage, plane.ageMap, rect: fullRect)
                        let colorAge = colorizer != nil ? maximum(bandCoverage, plane.colorAgeMap, rect: fullRect) : age
                        let layerColor = colorizer?.colorize(colorAge) ?? acc
                        let layer = blendWithMask(foreground: layerColor,
                                                  background: CIImage(color: .clear).cropped(to: fullRect),
                                                  maskAlpha: maskToAlpha(age), rect: fullRect)
                        planeDisplays.append((acc, age, colorAge, layer))
                    }
                    // Trails over the frozen plate (`.frozen`) or the live moving scene (`.live`).
                    let backdrop = liveBackdrop ? current : staticBackground
                    var displayed = blendWithMask(foreground: trailColor, background: backdrop,
                                                  maskAlpha: maskToAlpha(displayAgeMap), rect: fullRect)
                    // Ignore regions play the live video, not the frozen plate: show the current frame
                    // where keep = 0 (inside a region) and the trail composite where keep = 1 (outside).
                    if let keepMask {
                        displayed = blendWithMask(foreground: displayed, background: current,
                                                  maskAlpha: maskToAlpha(keepMask), rect: fullRect)
                    }
                    // This centre becomes output frame `written + 1` (the seed plate is frame 0).
                    if let handheld {
                        let time = Double(written + 1) / outputFPS
                        displayed = handheld.apply(to: displayed, at: time, frameRect: fullRect)
                        // Each near plane rides the same pose with its own pushed translation
                        // (roll and zoom shared — only translation parallaxes), composited far →
                        // near, so bigger marks sway progressively further than the scene and
                        // reveal what sits behind them.
                        for (i, planeDisplay) in planeDisplays.enumerated() {
                            displayed = sourceOver(handheld.apply(to: planeDisplay.layer, at: time, frameRect: fullRect,
                                                                  parallax: nearPlanes[i].push),
                                                   over: displayed, rect: fullRect)
                        }
                    }
                    exportFrame = prepareExport(displayed, cropRect: cropRect, scale: exportScale,
                                                outputRect: outputRect)

                    // Persist the silhouette only at snapshot frames.
                    if isSnapshot {
                        accumulator = flattener.flatten(displayAccumulator, rect: fullRect, context: context)
                        ageMap = flattener.flatten(displayAgeMap, rect: fullRect, context: context)
                        if colorizer != nil {
                            colorAgeMap = flattener.flatten(displayColorAgeMap, rect: fullRect, context: context)
                        }
                        for (i, planeDisplay) in planeDisplays.enumerated() {
                            nearPlanes[i].accumulator = flattener.flatten(planeDisplay.accumulator, rect: fullRect, context: context)
                            nearPlanes[i].ageMap = flattener.flatten(planeDisplay.ageMap, rect: fullRect, context: context)
                            if colorizer != nil {
                                nearPlanes[i].colorAgeMap = flattener.flatten(planeDisplay.colorAgeMap, rect: fullRect, context: context)
                            }
                        }
                    }
                case .mask:
                    exportFrame = prepareExport(mask.cropped(to: fullRect), cropRect: cropRect,
                                                scale: exportScale, outputRect: outputRect)
                }

                return try writer.makeFrameBuffer(exportFrame, context: context)
            }
        }

        // Emit one centre frame, then drop window frames no later centre will need.
        func emit(_ centre: Int) async throws {
            if let frameBuffer = try renderCentre(centre) {
                try await writer.append(frameBuffer)
                written += 1
                progress?(Self.analyzingShare + (1 - Self.analyzingShare) * min(1, Double(written) / Double(total)))
            }
            // Later centres only need this frame's proxy (as a ±K neighbour) — release the full-res
            // image now rather than when the frame leaves the window.
            window[centre - firstIndex].image = nil
            nextToProcess += 1
            let keepFrom = max(0, nextToProcess - horizon)
            if keepFrom > firstIndex {
                window.removeFirst(keepFrom - firstIndex)
                firstIndex = keepFrom
            }
        }

        var readIndex = 0
        while let raw = try reader.nextFrame() {
            try Task.checkCancellation()
            let oriented = raw.cropped(to: fullRect)
            // Decode-time work (brightness probe + optional stabilization + flatten into the ring
            // buffer's own GPU buffer, plus the mask-resolution proxy) inside a pool so its
            // temporaries don't accumulate.
            var bright = false
            let (frame, proxy) = autoreleasepool { () -> (CIImage, CIImage) in
                bright = BackgroundEstimator.meanLuma(oriented, rect: fullRect, context: context) >= darkLumaCutoff
                let aligned = (registrar?.align(oriented) ?? oriented).cropped(to: fullRect)
                let full = frameFlattener.flatten(aligned, rect: fullRect, context: context)
                guard let maskFlattener else { return (full, full) }
                let downscaled = full
                    .transformed(by: CGAffineTransform(scaleX: maskScaleX, y: maskScaleY))
                    .cropped(to: maskRect)
                return (full, maskFlattener.flatten(downscaled, rect: maskRect, context: context))
            }
            window.append(WindowFrame(image: frame, proxy: proxy, bright: bright))
            readIndex += 1
            // Process every centre that now has a full +K look-ahead.
            while nextToProcess <= readIndex - 1 - horizon {
                try await emit(nextToProcess)
            }
        }
        // Flush the tail: remaining centres use whatever look-ahead is left (`later` → nil at the end).
        while nextToProcess < readIndex {
            try await emit(nextToProcess)
        }

        try await writer.finish()
        progress?(1)
        renderSucceeded = true
        return outputURL
    }

    // MARK: - Output sizing

    /// Crops to aspect, re-anchors to origin, then scales for the output cap.
    private func prepareExport(_ image: CIImage, cropRect: CGRect, scale: CGFloat,
                               outputRect: CGRect) -> CIImage {
        var out = image
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
        if scale != 1 {
            out = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        return out.cropped(to: outputRect)
    }

    /// Even-dimensioned output size with the long edge capped at `maxDimension`.
    private func scaledOutputSize(_ size: CGSize, maxDimension: CGFloat) -> CGSize {
        let longEdge = max(size.width, size.height)
        let scale = min(1, maxDimension / longEdge)
        let w = max(2, Int((size.width * scale).rounded()) & ~1)
        let h = max(2, Int((size.height * scale).rounded()) & ~1)
        return CGSize(width: w, height: h)
    }

    // MARK: - Image helpers

    /// Moves the alpha (motion coverage) into an opaque grayscale image.
    private func alphaToGray(_ image: CIImage, rect: CGRect) -> CIImage {
        let m = CIFilter.colorMatrix()
        m.inputImage = image
        m.rVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        m.gVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        m.bVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        m.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return (m.outputImage ?? image).cropped(to: rect)
    }

    /// Scales an opaque grayscale image's value by `factor`.
    private func scaleGray(_ image: CIImage, _ factor: Double) -> CIImage {
        let f = CGFloat(factor)
        let m = CIFilter.colorMatrix()
        m.inputImage = image
        m.rVector = CIVector(x: f, y: 0, z: 0, w: 0)
        m.gVector = CIVector(x: 0, y: f, z: 0, w: 0)
        m.bVector = CIVector(x: 0, y: 0, z: f, w: 0)
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        m.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return m.outputImage ?? image
    }

    private func multiply(_ a: CIImage, _ b: CIImage, rect: CGRect) -> CIImage {
        let f = CIFilter.multiplyCompositing()
        f.inputImage = a
        f.backgroundImage = b
        return (f.outputImage ?? a).cropped(to: rect)
    }

    private func maximum(_ a: CIImage, _ b: CIImage, rect: CGRect) -> CIImage {
        let f = CIFilter.maximumCompositing()
        f.inputImage = a
        f.backgroundImage = b
        return (f.outputImage ?? a).cropped(to: rect)
    }

    private func maskToAlpha(_ grayscale: CIImage) -> CIImage {
        let f = CIFilter.maskToAlpha()
        f.inputImage = grayscale
        return f.outputImage ?? grayscale
    }

    private func blendWithMask(foreground: CIImage, background: CIImage, maskAlpha: CIImage, rect: CGRect) -> CIImage {
        let f = CIFilter.blendWithMask()
        f.inputImage = foreground
        f.backgroundImage = background
        f.maskImage = maskAlpha
        return (f.outputImage ?? background).cropped(to: rect)
    }

    /// Per-pixel "size of the blob this pixel belongs to" (0…1) for parallax classification.
    /// The blur turns binary coverage into the local coverage fraction of a σ-neighbourhood —
    /// a value that rises with blob size — and the dilate spreads each blob's peak across its
    /// whole footprint (feather rim included) so the later threshold classifies a mark as one
    /// unit instead of cutting per-pixel seams through it.
    private func blobSizeSignal(_ coverage: CIImage, rect: CGRect) -> CIImage {
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = coverage.clampedToExtent()
        blur.radius = Self.parallaxSizeSigma
        let dilate = CIFilter.morphologyMaximum()
        dilate.inputImage = blur.outputImage
        dilate.radius = Self.parallaxSizeSigma
        return (dilate.outputImage ?? coverage).cropped(to: rect)
    }

    /// Binarizes an opaque grayscale image at `cutoff` (`CIColorThreshold`).
    private func thresholdGray(_ image: CIImage, _ cutoff: Float, rect: CGRect) -> CIImage {
        let f = CIFilter.colorThreshold()
        f.inputImage = image
        f.threshold = cutoff
        return (f.outputImage ?? image).cropped(to: rect)
    }

    /// `1 − value` for an opaque grayscale image.
    private func invertGray(_ image: CIImage, rect: CGRect) -> CIImage {
        let m = CIFilter.colorMatrix()
        m.inputImage = image
        m.rVector = CIVector(x: -1, y: 0, z: 0, w: 0)
        m.gVector = CIVector(x: 0, y: -1, z: 0, w: 0)
        m.bVector = CIVector(x: 0, y: 0, z: -1, w: 0)
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        m.biasVector = CIVector(x: 1, y: 1, z: 1, w: 1)
        return (m.outputImage ?? image).cropped(to: rect)
    }

    /// Alpha-composites a transparent-backed layer over an opaque background.
    private func sourceOver(_ image: CIImage, over background: CIImage, rect: CGRect) -> CIImage {
        let f = CIFilter.sourceOverCompositing()
        f.inputImage = image
        f.backgroundImage = background
        return (f.outputImage ?? background).cropped(to: rect)
    }
}
