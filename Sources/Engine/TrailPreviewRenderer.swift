import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import AVFoundation
import Observation

/// Drives the live trail-density preview in the edit screen.
///
/// `prepare` builds, at a small proxy resolution, the background plate plus one subject cut-out per
/// snapshot; `recompose` then layers an evenly-spaced subset over the background — cheap enough to
/// run on every slider move. The expensive `prepare` work is done in a **single decode pass** (the
/// clip is the bottleneck — background estimation and layer extraction used to decode it twice) and
/// its result is **cached to disk per project**, keyed by the mask-affecting settings, so reopening
/// a project (or returning to the edit screen) reloads the proxy layers instead of re-decoding.
@Observable
final class TrailPreviewRenderer {
    private(set) var previewImage: CGImage?
    private(set) var isPreparing = false
    private(set) var isReady = false
    /// Set when `prepare` throws (e.g. an unreadable/corrupt source) so the UI can show a real
    /// message + retry instead of a permanent "Preparing preview…" spinner.
    private(set) var preparationFailed = false

    private var background: CIImage?          // frozen plate (temporal median)
    private var liveBackground: CIImage?      // live backdrop (last snapshot frame) for `.live` mode
    private var layers: [CIImage] = []        // ordered subject cut-outs (proxy res, flattened)
    private var proxyRect: CGRect = .zero
    private var clipDurationSeconds = 1.0

    private let context = SharedRender.ciContext
    private let maxSnapshots = 96
    private let maxProxyEdge: CGFloat = 480
    /// How many prepared previews (distinct mask-setting combinations) are kept on disk per
    /// project, so revisiting a recent slider value reloads instead of re-decoding.
    private let maxCacheEntries = 4
    // Bump when the preview pipeline or mask algorithm changes, or stale caches will load.
    // v2: temporal (fast-vs-slow) detection replaced static-background differencing.
    // v3: cache now also carries a live backdrop (Frozen/Live background toggle).
    // v4: ignore regions are baked into the layers; cache moved to per-key subdirectories (LRU).
    // v5: ignore brush strokes + feathered keep-mask edges.
    // v6: both-or-nothing temporal pair (no one-sided ghosts at clip ends) + r1 despeckle open.
    private let cacheVersion = 6

    private var recomposeTask: Task<Void, Never>?

    /// Immutable product of `prepare` — the proxy backdrops and trail cut-outs for a clip. Both
    /// backdrops are kept so the Frozen/Live toggle is a cheap `recompose`, not a re-decode.
    struct PreviewData {
        let background: CIImage
        let liveBackground: CIImage
        let layers: [CIImage]
        let proxyRect: CGRect
        let durationSeconds: Double
    }

    /// Build (or load) the proxy background + subject layers. Call when the source or a mask-affecting
    /// setting (contrast mode, stabilization, background mode) changes. `cacheDirectory` (the project
    /// directory) enables the on-disk cache; pass `nil` to always recompute.
    func prepare(sourceURL: URL, settings: RenderSettings, cacheDirectory: URL? = nil) async {
        await MainActor.run {
            isPreparing = true
            preparationFailed = false
        }
        let key = cacheKey(settings)

        // Fast path: reuse a previously prepared preview for these mask settings.
        if let cacheDirectory, let data = loadCache(directory: cacheDirectory, key: key) {
            await apply(data)
            recompose(settings: settings)
            return
        }

        do {
            let data = try await computeProxyPreview(sourceURL: sourceURL, settings: settings)
            if let cacheDirectory { try? saveCache(data, directory: cacheDirectory, key: key) }
            await apply(data)
            recompose(settings: settings)
        } catch {
            await MainActor.run {
                self.isPreparing = false
                self.preparationFailed = true
            }
        }
    }

    @MainActor private func apply(_ data: PreviewData) {
        background = data.background
        liveBackground = data.liveBackground
        layers = data.layers
        proxyRect = data.proxyRect
        clipDurationSeconds = data.durationSeconds
        isPreparing = false
        isReady = true
        preparationFailed = false
    }

    // MARK: - Compute (single decode pass, proxy resolution)

    private func computeProxyPreview(sourceURL: URL, settings: RenderSettings) async throws -> PreviewData {
        let reader = try await VideoFrameReader(url: sourceURL)
        let fullSize = reader.info.orientedSize
        let fullRect = CGRect(origin: .zero, size: fullSize)
        let frameCount = max(1, reader.info.estimatedFrameCount)
        let duration = max(0.1, reader.info.duration.seconds)

        let scale = min(1, maxProxyEdge / max(fullSize.width, fullSize.height))
        let pw = max(2, Int((fullSize.width * scale).rounded()) & ~1)
        let ph = max(2, Int((fullSize.height * scale).rounded()) & ~1)
        let pRect = CGRect(x: 0, y: 0, width: pw, height: ph)
        let pSize = CGSize(width: pw, height: ph)
        let scaleT = CGAffineTransform(scaleX: scale, y: scale)
        let rowBytes = pw * 4
        let cs = CGColorSpaceCreateDeviceRGB()

        // ONE decode pass with a bounded ±K proxy delay-line (mirrors the engine). Every frame after
        // the leading dark fade is downscaled into a small ring of recent proxy buffers; a snapshot's
        // subject layer is cut once its +K look-ahead frame is decoded, using the TRUE proxy frames K
        // positions before/after it — so the motion-sensitivity (horizon) drives the preview exactly,
        // not an adjacent-sample approximation. Only ~2K+2 proxy buffers are resident at once; the
        // kept layers stay GPU-resident.
        try reader.start()
        let snapStride = max(1, frameCount / maxSnapshots)
        let horizon = settings.motionHorizonFrames(fps: Double(reader.info.nominalFrameRate))
        let ringCapacity = 2 * horizon + 2
        let flattener = PixelBufferFlattener(size: pSize, colorSpace: context.workingColorSpace ?? cs)
        let extractor = SubjectLayerExtractor()
        // Ignore regions are cut out of every proxy layer (same keep-mask the engine multiplies
        // into its motion mask), so masked areas show no trails in the preview either.
        let keepAlpha = IgnoreMaskBuilder.keepMask(regions: settings.ignoreRegions,
                                                   strokes: settings.ignoreStrokes, size: pSize)
            .map(Self.maskToAlpha)

        func image(_ buf: [UInt8]) -> CIImage {
            CIImage(bitmapData: Data(buf), bytesPerRow: rowBytes, size: pSize, format: .RGBA8, colorSpace: cs)
        }

        var ring: [[UInt8]] = []        // recent proxy frames; ring[0] has bright-index `ringStart`
        var ringStart = 0
        var head = -1                   // bright-index of the newest frame in the ring
        var sawBright = false
        var snapshots: [[UInt8]] = []   // kept snapshot (centre) buffers — feed the plate
        var layers: [CIImage] = []

        // Nearest ring frame on one side of the centre, scanning *inward* from ±K — at the clip's
        // ends the horizon shrinks instead of the side vanishing. Like the engine, the pair is
        // used both-or-nothing: a one-sided difference leaves the trailing "ghost" the symmetric
        // min removes, which cut sky-coloured ghost layers at the first/last snapshots.
        func temporalReference(centre bi: Int, step: Int) -> CIImage? {
            var gi = bi + step * horizon
            while gi != bi {
                if gi >= ringStart, gi - ringStart < ring.count { return image(ring[gi - ringStart]) }
                gi -= step
            }
            return nil
        }
        func emitCentre(_ bi: Int) {
            guard layers.count < maxSnapshots, bi >= ringStart, bi - ringStart < ring.count else { return }
            let centre = ring[bi - ringStart]
            let earlier = temporalReference(centre: bi, step: -1)
            let later = temporalReference(centre: bi, step: +1)
            let bothSides = earlier != nil && later != nil
            var layer = extractor.subjectLayer(frame: image(centre),
                                               earlier: bothSides ? earlier : nil,
                                               later: bothSides ? later : nil,
                                               settings: settings, radiusScale: scale)
            if let keepAlpha {
                layer = Self.blendWithMask(foreground: layer, background: CIImage.empty(),
                                           maskAlpha: keepAlpha, rect: pRect)
            }
            layers.append(flattener.flatten(layer, rect: pRect, context: context))
            snapshots.append(centre)
        }

        while layers.count < maxSnapshots, let raw = try reader.nextFrame() {
            try Task.checkCancellation()
            autoreleasepool {
                let frame = raw.cropped(to: fullRect)
                if !sawBright {
                    if BackgroundEstimator.meanLuma(frame, rect: fullRect, context: context) < 0.06 { return }
                    sawBright = true
                }
                head += 1
                var buf = [UInt8](repeating: 0, count: rowBytes * ph)
                buf.withUnsafeMutableBytes { ptr in
                    context.render(frame.transformed(by: scaleT).cropped(to: pRect), toBitmap: ptr.baseAddress!,
                                   rowBytes: rowBytes, bounds: pRect, format: .RGBA8, colorSpace: cs)
                }
                ring.append(buf)
                let overflow = ring.count - ringCapacity
                if overflow > 0 { ring.removeFirst(overflow); ringStart += overflow }
                // The centre that now has its full +K look-ahead becomes ready.
                let centre = head - horizon
                if centre >= 0 && centre % snapStride == 0 { emitCentre(centre) }
            }
        }
        // Flush tail centres (no +K look-ahead left → `later` neighbour is nil, like the engine's end).
        var c = head - horizon >= 0 ? ((head - horizon) / snapStride + 1) * snapStride : 0
        while c <= head && layers.count < maxSnapshots { emitCentre(c); c += snapStride }
        guard !snapshots.isEmpty else { throw VideoIOError.readerFailed(nil) }

        // Proxy background plate = per-pixel temporal median of ~19 evenly-spaced snapshots. Still the
        // composite base in `recompose` (not a detection reference).
        let bgBytes = Self.median(of: Self.evenlySpaced(snapshots, count: min(19, snapshots.count)),
                                  width: pw, height: ph)
        let bgImage = CIImage(bitmapData: Data(bgBytes), bytesPerRow: rowBytes,
                              size: pSize, format: .RGBA8, colorSpace: cs)
        let background = flattener.flatten(bgImage, rect: pRect, context: context)
        // Live backdrop = the last snapshot's full frame — representative of the final rendered frame's
        // moving scene (the preview is a still of that final frame).
        let liveBackground = flattener.flatten(image(snapshots.last!), rect: pRect, context: context)

        return PreviewData(background: background, liveBackground: liveBackground,
                           layers: layers, proxyRect: pRect, durationSeconds: duration)
    }

    /// Recomposite the selected snapshot subset for the current frequency, trail mode, fade and
    /// color style. Cheap; safe to call on every slider change.
    ///
    /// Fade/color parity: the engine fades its age map by `ageDecay` per output frame, its colour-age
    /// map by `gradientDecay`, and (for `.ageGradient`) replaces trail pixels with the colour-age-
    /// mapped gradient. The preview shows the *final* frame, so each snapshot's ages there are
    /// `decay^(framesSinceSnapshot)` — the fade age applied as a per-layer opacity (the engine's fade
    /// blends the trail toward the backdrop by exactly that value), the colour age as a per-layer
    /// tint along the settings' gradient endpoints.
    func recompose(settings: RenderSettings) {
        recomposeTask?.cancel()
        let layers = self.layers
        guard !layers.isEmpty, let background = self.background else { return }
        let rect = proxyRect
        let count = max(1, min(layers.count, settings.snapshotCount(durationSeconds: clipDurationSeconds)))
        let mode = settings.trailMode
        let decay = settings.ageDecay
        let gradientTint = settings.colorStyle == .ageGradient
        let colorDecay = settings.gradientDecay
        let oldest = settings.gradientOldest
        let newest = settings.gradientNewest
        let framesPerSnapshot = settings.snapshotIntervalSeconds * Double(settings.outputFPS)
        // Frozen plate vs. live scene — the toggle is just which backdrop the layers sit over.
        let backdrop = settings.backgroundMode == .live ? (liveBackground ?? background) : background

        recomposeTask = Task {
            let selected = Self.evenlySpaced(layers, count: count)
            var composite = backdrop

            func styled(_ layer: CIImage, framesSinceSnapshot: Double) -> CIImage {
                var out = layer
                if gradientTint {
                    let colorAge = pow(colorDecay, framesSinceSnapshot)
                    out = Self.tinted(out, color: Self.gradientColor(colorAge, oldest: oldest, newest: newest))
                }
                var opacity = mode == .overlay ? 0.5 : 1.0
                if decay < 1 { opacity *= pow(decay, framesSinceSnapshot) }
                if opacity < 1 { out = Self.scaledAlpha(out, opacity) }
                return out
            }

            for (i, layer) in selected.enumerated() {
                composite = styled(layer, framesSinceSnapshot: Double(selected.count - 1 - i) * framesPerSnapshot)
                    .composited(over: composite)
            }
            // Draw the final frame's subject on top — the engine shows the live subject on the last
            // frame, so this keeps the preview matching the rendered video's final frame.
            if let last = layers.last {
                let live = gradientTint
                    ? Self.tinted(last, color: Self.gradientColor(1, oldest: oldest, newest: newest))
                    : last
                composite = live.composited(over: composite)
            }
            let cg = context.createCGImage(composite, from: rect)
            if Task.isCancelled { return }
            await MainActor.run { self.previewImage = cg }
        }
    }

    // MARK: - On-disk cache

    /// Identifies a cached preview. Only mask-affecting inputs matter (trail frequency/mode/fade/
    /// color are applied later in `recompose`, not baked into the layers). Ignore regions *are*
    /// baked into the layers, so they are part of the key.
    private func cacheKey(_ settings: RenderSettings) -> String {
        let h = Int((settings.motionHorizonSeconds * 100).rounded())
        return "v\(cacheVersion)|\(settings.contrastMode.rawValue)|h\(h)|e\(Int(maxProxyEdge))|n\(maxSnapshots)|ir\(Self.stableHash(settings.ignoreFingerprint))"
    }

    /// Stable (FNV-1a) hex digest — `Hasher` is seeded per launch, so it can't key an on-disk cache.
    private static func stableHash(_ s: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    private struct CacheMeta: Codable {
        let key: String
        let proxyW: Int
        let proxyH: Int
        let count: Int
        let duration: Double
    }

    private func cacheDirectory(_ projectDirectory: URL) -> URL {
        projectDirectory.appendingPathComponent("preview.cache", isDirectory: true)
    }

    /// One subdirectory per prepared settings combination, so recent slider values stay warm.
    private func entryDirectory(_ projectDirectory: URL, key: String) -> URL {
        cacheDirectory(projectDirectory).appendingPathComponent(Self.stableHash(key), isDirectory: true)
    }

    private func loadCache(directory: URL, key: String) -> PreviewData? {
        let dir = entryDirectory(directory, key: key)
        guard let metaData = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
              let meta = try? JSONDecoder().decode(CacheMeta.self, from: metaData),
              meta.key == key, meta.count > 0 else { return nil }
        // Touch the entry so LRU pruning keeps recently used combinations.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: dir.path)

        let pRect = CGRect(x: 0, y: 0, width: meta.proxyW, height: meta.proxyH)
        let cs = context.workingColorSpace ?? CGColorSpaceCreateDeviceRGB()
        let flattener = PixelBufferFlattener(size: pRect.size, colorSpace: cs)

        guard let bgImage = CIImage(contentsOf: dir.appendingPathComponent("background.png")),
              let liveImage = CIImage(contentsOf: dir.appendingPathComponent("livebackground.png")) else { return nil }
        let background = flattener.flatten(bgImage.cropped(to: pRect), rect: pRect, context: context)
        let liveBackground = flattener.flatten(liveImage.cropped(to: pRect), rect: pRect, context: context)

        var layers: [CIImage] = []
        layers.reserveCapacity(meta.count)
        for i in 0..<meta.count {
            let url = dir.appendingPathComponent(String(format: "layer-%03d.png", i))
            guard let img = CIImage(contentsOf: url) else { return nil }
            layers.append(flattener.flatten(img.cropped(to: pRect), rect: pRect, context: context))
        }
        return PreviewData(background: background, liveBackground: liveBackground,
                           layers: layers, proxyRect: pRect, durationSeconds: meta.duration)
    }

    private func saveCache(_ data: PreviewData, directory: URL, key: String) throws {
        let root = cacheDirectory(directory)
        // Clear pre-v4 flat-layout files (meta.json/pngs at the root) once.
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("meta.json").path) {
            try? FileManager.default.removeItem(at: root)
        }
        let dir = entryDirectory(directory, key: key)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let pngColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        try context.writePNGRepresentation(of: data.background,
                                           to: dir.appendingPathComponent("background.png"),
                                           format: .RGBA8, colorSpace: pngColorSpace)
        try context.writePNGRepresentation(of: data.liveBackground,
                                           to: dir.appendingPathComponent("livebackground.png"),
                                           format: .RGBA8, colorSpace: pngColorSpace)
        for (i, layer) in data.layers.enumerated() {
            try context.writePNGRepresentation(of: layer,
                                               to: dir.appendingPathComponent(String(format: "layer-%03d.png", i)),
                                               format: .RGBA8, colorSpace: pngColorSpace)
        }
        let meta = CacheMeta(key: key, proxyW: Int(data.proxyRect.width), proxyH: Int(data.proxyRect.height),
                             count: data.layers.count, duration: data.durationSeconds)
        try JSONEncoder().encode(meta).write(to: dir.appendingPathComponent("meta.json"))
        pruneCache(root: root, keeping: dir)
    }

    /// Drops the least-recently-used entries beyond `maxCacheEntries`.
    private func pruneCache(root: URL, keeping current: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root,
                                                        includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]) else { return }
        let dirs = entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
        guard dirs.count > maxCacheEntries else { return }
        let dated = dirs.map { url -> (URL, Date) in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return (url, date)
        }.sorted { $0.1 < $1.1 }
        for (url, _) in dated.prefix(dirs.count - maxCacheEntries) where url != current {
            try? fm.removeItem(at: url)
        }
    }

    // MARK: - Helpers

    private static func evenlySpaced<T>(_ items: [T], count: Int) -> [T] {
        guard !items.isEmpty, count >= 1 else { return items }
        if count >= items.count { return items }
        if count == 1 { return [items[items.count / 2]] }
        return (0..<count).map { j in
            items[Int((Double(j) * Double(items.count - 1) / Double(count - 1)).rounded())]
        }
    }

    /// Per-pixel, per-channel temporal median across `samples` (each `width*height*4` RGBA8).
    private static func median(of samples: [[UInt8]], width: Int, height: Int) -> [UInt8] {
        let rowBytes = width * 4
        guard let first = samples.first else { return [UInt8](repeating: 0, count: rowBytes * height) }
        let n = samples.count
        if n == 1 { return first }
        var output = [UInt8](repeating: 0, count: rowBytes * height)
        let mid = n / 2
        output.withUnsafeMutableBufferPointer { out in
            nonisolated(unsafe) let outBase = out.baseAddress!
            DispatchQueue.concurrentPerform(iterations: height) { row in
                var scratch = [UInt8](repeating: 0, count: n)
                let rowStart = row * rowBytes
                for x in 0..<width {
                    let base = rowStart + x * 4
                    for c in 0..<3 {
                        for k in 0..<n { scratch[k] = samples[k][base + c] }
                        scratch.sort()
                        outBase[base + c] = scratch[mid]
                    }
                    outBase[base + 3] = 255
                }
            }
        }
        return output
    }

    private static func scaledAlpha(_ image: CIImage, _ opacity: Double) -> CIImage {
        let m = CIFilter.colorMatrix()
        m.inputImage = image
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))
        m.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        return m.outputImage ?? image
    }

    /// Replaces the layer's RGB with a flat color, preserving its alpha (silhouette) — the preview
    /// analogue of the engine's age-gradient color map, which paints trail pixels by age.
    private static func tinted(_ image: CIImage, color: CIColor) -> CIImage {
        let m = CIFilter.colorMatrix()
        m.inputImage = image
        m.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        m.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        m.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        m.biasVector = CIVector(x: color.red, y: color.green, z: color.blue, w: 0)
        return m.outputImage ?? image
    }

    /// Linear blend along the age gradient (`age` 1 = newest, 0 = oldest) — the preview analogue of
    /// the engine's `TrailColorizer` colour map, sharing the settings' endpoints.
    private static func gradientColor(_ age: Double, oldest: RenderSettings.GradientColor,
                                      newest: RenderSettings.GradientColor) -> CIColor {
        let t = min(max(age, 0), 1)
        return CIColor(red: oldest.red + (newest.red - oldest.red) * t,
                       green: oldest.green + (newest.green - oldest.green) * t,
                       blue: oldest.blue + (newest.blue - oldest.blue) * t)
    }

    private static func maskToAlpha(_ grayscale: CIImage) -> CIImage {
        let f = CIFilter.maskToAlpha()
        f.inputImage = grayscale
        return f.outputImage ?? grayscale
    }

    private static func blendWithMask(foreground: CIImage, background: CIImage,
                                      maskAlpha: CIImage, rect: CGRect) -> CIImage {
        let f = CIFilter.blendWithMask()
        f.inputImage = foreground
        f.backgroundImage = background
        f.maskImage = maskAlpha
        return (f.outputImage ?? background).cropped(to: rect)
    }
}
