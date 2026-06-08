import CoreImage
import CoreImage.CIFilterBuiltins
import AVFoundation
import Observation

/// Drives the live trail-density preview in the edit screen.
///
/// `prepare` decodes the clip once and caches each snapshot's subject cut-out at a small proxy
/// resolution. `recompose` then layers an evenly-spaced subset over the background — cheap enough
/// to run on every slider move — so the user sees the final composition get denser/sparser as the
/// trail-frequency slider changes, without re-rendering the MP4.
@Observable
final class TrailPreviewRenderer {
    private(set) var previewImage: CGImage?
    private(set) var isPreparing = false
    private(set) var isReady = false

    private var background: CIImage?
    private var layers: [CIImage] = []        // ordered subject cut-outs (proxy res, flattened)
    private var proxyRect: CGRect = .zero
    private var clipFrameCount = 1

    private let context = SharedRender.ciContext
    private let extractor = SubjectLayerExtractor()
    private let maxSnapshots = 48
    private let maxProxyEdge: CGFloat = 480

    private var recomposeTask: Task<Void, Never>?

    /// Decode the clip, build the background, and cache subject layers. Call when the source or a
    /// mask-affecting setting (sensitivity, min size, stabilization, background mode) changes.
    func prepare(sourceURL: URL, settings: RenderSettings) async {
        await MainActor.run { isPreparing = true }
        do {
            let reader = try await VideoFrameReader(url: sourceURL)
            let fullSize = reader.info.orientedSize
            let fullRect = CGRect(origin: .zero, size: fullSize)
            clipFrameCount = max(1, reader.info.estimatedFrameCount)

            let scale = min(1, maxProxyEdge / max(fullSize.width, fullSize.height))
            let pw = max(2, Int((fullSize.width * scale).rounded()) & ~1)
            let ph = max(2, Int((fullSize.height * scale).rounded()) & ~1)
            let pRect = CGRect(x: 0, y: 0, width: pw, height: ph)
            let scaleTransform = CGAffineTransform(scaleX: scale, y: scale)
            let workingColorSpace = context.workingColorSpace ?? CGColorSpaceCreateDeviceRGB()
            let flattener = PixelBufferFlattener(size: CGSize(width: pw, height: ph), colorSpace: workingColorSpace)

            let bgFull = try await BackgroundEstimator().estimate(url: sourceURL, cropRect: fullRect)
            let bgProxy = flattener.flatten(bgFull.transformed(by: scaleTransform).cropped(to: pRect),
                                            rect: pRect, context: context)

            try reader.start()
            let snapStride = max(1, clipFrameCount / maxSnapshots)
            var index = 0
            var sawBright = false
            var cached: [CIImage] = []
            while let raw = try reader.nextFrame() {
                if Task.isCancelled { break }
                let frame = raw.cropped(to: fullRect)
                if !sawBright {
                    if BackgroundEstimator.meanLuma(frame, rect: fullRect, context: context) < 0.06 { continue }
                    sawBright = true
                }
                defer { index += 1 }
                guard index % snapStride == 0 else { continue }
                // Mask at proxy resolution — ~`scale²` fewer pixels than the engine's full-res mask,
                // cheap enough to re-run on every mask-affecting slider change. `radiusScale` keeps
                // the morphology feature size matched to the downscaled frame. Slightly coarser edges
                // than the final render, which is an acceptable trade for a live preview.
                let frameProxy = frame.transformed(by: scaleTransform).cropped(to: pRect)
                let layerProxy = extractor.subjectLayer(frame: frameProxy, background: bgProxy,
                                                        settings: settings, radiusScale: scale)
                cached.append(flattener.flatten(layerProxy, rect: pRect, context: context))
                if cached.count >= maxSnapshots { break }
            }

            await MainActor.run {
                self.background = bgProxy
                self.layers = cached
                self.proxyRect = pRect
                self.isPreparing = false
                self.isReady = true
            }
            recompose(settings: settings)
        } catch {
            await MainActor.run { self.isPreparing = false }
        }
    }

    /// Recomposite the selected snapshot subset for the current frequency / trail mode. Cheap;
    /// safe to call on every slider change.
    func recompose(settings: RenderSettings) {
        recomposeTask?.cancel()
        let layers = self.layers
        guard !layers.isEmpty, let background = self.background else { return }
        let rect = proxyRect
        let count = max(1, min(layers.count, settings.snapshotCount(forFrameCount: clipFrameCount)))
        let mode = settings.trailMode

        recomposeTask = Task {
            let selected = Self.evenlySpaced(layers, count: count)
            var composite = background
            for layer in selected {
                composite = (mode == .overlay ? Self.halfAlpha(layer) : layer).composited(over: composite)
            }
            // Draw the final frame's subject on top — the engine shows the live subject on the last
            // frame, so this keeps the preview matching the rendered video's final frame.
            if let last = layers.last { composite = last.composited(over: composite) }
            let cg = context.createCGImage(composite, from: rect)
            if Task.isCancelled { return }
            await MainActor.run { self.previewImage = cg }
        }
    }

    // MARK: - Helpers

    private static func evenlySpaced(_ layers: [CIImage], count: Int) -> [CIImage] {
        guard count > 1 else { return [layers[layers.count / 2]] }
        if count >= layers.count { return layers }
        return (0..<count).map { j in
            layers[Int((Double(j) * Double(layers.count - 1) / Double(count - 1)).rounded())]
        }
    }

    private static func halfAlpha(_ image: CIImage) -> CIImage {
        let m = CIFilter.colorMatrix()
        m.inputImage = image
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 0.5)
        m.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        return m.outputImage ?? image
    }
}
