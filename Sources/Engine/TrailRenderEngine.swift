import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Orchestrates the offline trail render (spec §11). Reads source frames, builds a motion mask
/// against the background (minus any ignore regions), composites with persistent replacement or
/// overlay, maintains a per-pixel **age map** that drives trail fade and age-gradient color, then
/// crops/scales/watermarks and encodes each accumulated state to an MP4.
///
/// `render` is async and cancellable; it reports fractional progress as frames are written.
/// Processing runs at the full oriented resolution; crop, 4K cap, and watermark are applied last
/// (spec §11.1, §7.6, §8).
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

    func render(
        sourceURL: URL,
        settings: RenderSettings,
        output: Output = .trail,
        watermark: Bool = false,
        maxOutputDimension: CGFloat = .greatestFiniteMagnitude,
        progress: (@Sendable (Double) -> Void)? = nil,
        stage: (@Sendable (RenderStage) -> Void)? = nil
    ) async throws -> URL {
        let reader = try await VideoFrameReader(url: sourceURL)
        let info = reader.info
        let fullSize = info.orientedSize
        let fullRect = CGRect(origin: .zero, size: fullSize)

        // Social crop (after processing, §11.1), then a 4K/tier downscale (§8, §16).
        let cropRect = settings.cropAspect.cropRect(in: fullSize)
        let outputSize = scaledOutputSize(cropRect.size, maxDimension: maxOutputDimension)
        let outputRect = CGRect(origin: .zero, size: outputSize)
        let exportScale = outputSize.width / cropRect.size.width

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("trail-\(UUID().uuidString).mp4")
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
        let maskBuilder = MotionMaskBuilder()
        let compositor = TrailCompositor()
        let watermarkImage: CIImage? = watermark ? WatermarkRenderer().makeWatermark(outputSize: outputSize) : nil
        let colorizer = settings.colorStyle == .ageGradient ? TrailColorizer() : nil
        let keepMask = IgnoreMaskBuilder.keepMask(regions: settings.ignoreRegions, size: fullSize)

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
        // Display backdrop: trails composite over the frozen plate, or over the live current frame.
        let liveBackdrop = settings.backgroundMode == .live

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

        // Seed the output with the clean background as frame 0.
        if output == .trail {
            let seedBuffer = try autoreleasepool {
                try writer.makeFrameBuffer(
                    prepareExport(staticBackground, cropRect: cropRect, scale: exportScale,
                                  outputRect: outputRect, watermark: watermarkImage),
                    context: context)
            }
            await writer.append(seedBuffer)
        }

        // Delay-line over the decoded stream so each processed "centre" frame has its ±K neighbours
        // available. At most 2K+1 flattened frames are resident at once (bounded regardless of clip
        // length, so the long-clip memory invariant holds). Each frame stores whether it's bright, so
        // a dark fade neighbour can be skipped rather than flooding the temporal difference.
        struct WindowFrame { let image: CIImage; let bright: Bool }
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

                // ±K neighbours; a dark fade neighbour is treated as missing so the temporal diff
                // isn't flooded across a fade boundary (the symmetric min then uses the clean side).
                func neighbour(_ gi: Int) -> CIImage? {
                    guard gi >= firstIndex, gi - firstIndex < window.count else { return nil }
                    let n = window[gi - firstIndex]
                    return n.bright ? n.image : nil
                }
                let current = rec.image   // already oriented, registered and flattened at decode time
                let rawMask = maskBuilder.makeMask(current: current,
                                                   earlier: neighbour(centre - horizon),
                                                   later: neighbour(centre + horizon),
                                                   settings: settings)
                var coverage = alphaToGray(rawMask, rect: fullRect)
                if let keepMask { coverage = multiply(coverage, keepMask, rect: fullRect) }
                let mask = maskToAlpha(coverage)

                let exportFrame: CIImage
                switch output {
                case .trail:
                    // Fade the persistent trail every frame for smooth decay.
                    if decay < 1 { ageMap = flattener.flatten(scaleGray(ageMap, decay), rect: fullRect, context: context) }

                    // Display = persistent trail + the current (live) subject on top → smooth motion.
                    let displayAccumulator = compositor.compose(current: current, over: accumulator, mask: mask, mode: settings.trailMode)
                    let displayAgeMap = maximum(coverage, ageMap, rect: fullRect)
                    let trailColor = colorizer?.colorize(displayAgeMap) ?? displayAccumulator
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
                    exportFrame = prepareExport(displayed, cropRect: cropRect, scale: exportScale,
                                                outputRect: outputRect, watermark: watermarkImage)

                    // Persist the silhouette only at snapshot frames.
                    if isSnapshot {
                        accumulator = flattener.flatten(displayAccumulator, rect: fullRect, context: context)
                        ageMap = flattener.flatten(displayAgeMap, rect: fullRect, context: context)
                    }
                case .mask:
                    exportFrame = prepareExport(mask.cropped(to: fullRect), cropRect: cropRect,
                                                scale: exportScale, outputRect: outputRect, watermark: nil)
                }

                return try writer.makeFrameBuffer(exportFrame, context: context)
            }
        }

        // Emit one centre frame, then drop window frames no later centre will need.
        func emit(_ centre: Int) async throws {
            if let frameBuffer = try renderCentre(centre) {
                await writer.append(frameBuffer)
                written += 1
                progress?(Self.analyzingShare + (1 - Self.analyzingShare) * min(1, Double(written) / Double(total)))
            }
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
            // buffer's own GPU buffer) inside a pool so its temporaries don't accumulate.
            var bright = false
            let frame = autoreleasepool { () -> CIImage in
                bright = BackgroundEstimator.meanLuma(oriented, rect: fullRect, context: context) >= darkLumaCutoff
                let aligned = (registrar?.align(oriented) ?? oriented).cropped(to: fullRect)
                return frameFlattener.flatten(aligned, rect: fullRect, context: context)
            }
            window.append(WindowFrame(image: frame, bright: bright))
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

        await writer.finish()
        progress?(1)
        return outputURL
    }

    // MARK: - Output sizing

    /// Crops to aspect, re-anchors to origin, scales for the output cap, then watermarks.
    private func prepareExport(_ image: CIImage, cropRect: CGRect, scale: CGFloat,
                               outputRect: CGRect, watermark: CIImage?) -> CIImage {
        var out = image
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
        if scale != 1 {
            out = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        out = out.cropped(to: outputRect)
        guard let watermark else { return out }
        return WatermarkRenderer().apply(watermark, to: out, outputRect: outputRect)
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
}
