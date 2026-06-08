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

    func render(
        sourceURL: URL,
        settings: RenderSettings,
        output: Output = .trail,
        watermark: Bool = false,
        maxOutputDimension: CGFloat = .greatestFiniteMagnitude,
        progress: (@Sendable (Double) -> Void)? = nil
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
        let maskBuilder = MotionMaskBuilder()
        let compositor = TrailCompositor()
        let watermarkImage: CIImage? = watermark ? WatermarkRenderer().makeWatermark(outputSize: outputSize) : nil
        let colorizer = settings.colorStyle == .ageGradient ? TrailColorizer() : nil
        let keepMask = IgnoreMaskBuilder.keepMask(regions: settings.ignoreRegions, size: fullSize)

        // Static background reference = temporal median across the clip (spec §11.2).
        let staticBackground = try await BackgroundEstimator().estimate(url: sourceURL, cropRect: fullRect)
        let slowUpdate = settings.backgroundMode == .slowUpdate
        let decay = settings.ageDecay
        var dynamicBackground = staticBackground

        let registrar = settings.stabilizationEnabled ? FrameRegistrar(reference: staticBackground) : nil

        // Trail frequency → how many evenly-spaced snapshots leave a *persistent* silhouette in
        // the trail. The live subject is still drawn on top of every frame, so motion stays smooth
        // regardless of frequency; only the permanence of the trail changes.
        let snapshotCount = settings.snapshotCount(forFrameCount: info.estimatedFrameCount)

        let total = max(1, info.estimatedFrameCount)
        var written = 0
        var processedIndex = 0
        var sawBright = false
        var accumulator = staticBackground   // persistent trail (subject colors)
        var ageMap = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: fullRect)  // persistent recency

        // Seed the output with the clean background as frame 0.
        if output == .trail {
            let seed = prepareExport(staticBackground, cropRect: cropRect, scale: exportScale,
                                     outputRect: outputRect, watermark: watermarkImage)
            try await writer.append(seed, context: context)
        }

        while let raw = try reader.nextFrame() {
            try Task.checkCancellation()
            let frame = raw.cropped(to: fullRect)

            if !sawBright {
                if BackgroundEstimator.meanLuma(frame, rect: fullRect, context: context) < 0.06 { continue }
                sawBright = true
            }
            defer { processedIndex += 1 }
            // ~`snapshotCount` evenly-spaced frames leave a permanent mark.
            let isSnapshot = processedIndex == 0 ||
                Int(Double(processedIndex) * Double(snapshotCount) / Double(total)) >
                Int(Double(processedIndex - 1) * Double(snapshotCount) / Double(total))

            let aligned = (registrar?.align(frame) ?? frame).cropped(to: fullRect)
            let backgroundForMask = slowUpdate ? dynamicBackground : staticBackground
            let rawMask = maskBuilder.makeMask(current: aligned, background: backgroundForMask, settings: settings)
            var coverage = alphaToGray(rawMask, rect: fullRect)
            if let keepMask { coverage = multiply(coverage, keepMask, rect: fullRect) }
            let mask = maskToAlpha(coverage)

            switch output {
            case .trail:
                // Fade the persistent trail every frame for smooth decay.
                if decay < 1 { ageMap = flattener.flatten(scaleGray(ageMap, decay), rect: fullRect, context: context) }

                // Display = persistent trail + the current (live) subject on top → smooth motion.
                let displayAccumulator = compositor.compose(current: aligned, over: accumulator, mask: mask, mode: settings.trailMode)
                let displayAgeMap = maximum(coverage, ageMap, rect: fullRect)
                let trailColor = colorizer?.colorize(displayAgeMap) ?? displayAccumulator
                let displayed = blendWithMask(foreground: trailColor, background: staticBackground,
                                              maskAlpha: maskToAlpha(displayAgeMap), rect: fullRect)
                let exportFrame = prepareExport(displayed, cropRect: cropRect, scale: exportScale,
                                                outputRect: outputRect, watermark: watermarkImage)
                try await writer.append(exportFrame, context: context)

                // Persist the silhouette only at snapshot frames.
                if isSnapshot {
                    accumulator = flattener.flatten(displayAccumulator, rect: fullRect, context: context)
                    ageMap = flattener.flatten(displayAgeMap, rect: fullRect, context: context)
                    if slowUpdate {
                        dynamicBackground = updateBackground(dynamicBackground, with: aligned, mask: mask, rect: fullRect, flattener: flattener, context: context)
                    }
                }
            case .mask:
                let exportFrame = prepareExport(mask.cropped(to: fullRect), cropRect: cropRect,
                                                scale: exportScale, outputRect: outputRect, watermark: nil)
                try await writer.append(exportFrame, context: context)
            }

            written += 1
            progress?(min(1, Double(written) / Double(total)))
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

    private func updateBackground(_ background: CIImage, with current: CIImage, mask: CIImage,
                                  rect: CGRect, flattener: PixelBufferFlattener, context: CIContext) -> CIImage {
        let mixed = setAlpha(current, 0.05).composited(over: background)
        let updated = blendWithMask(foreground: background, background: mixed, maskAlpha: mask, rect: rect)
        return flattener.flatten(updated, rect: rect, context: context)
    }

    private func setAlpha(_ image: CIImage, _ alpha: CGFloat) -> CIImage {
        let m = CIFilter.colorMatrix()
        m.inputImage = image
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        m.biasVector = CIVector(x: 0, y: 0, z: 0, w: alpha)
        return m.outputImage ?? image
    }
}
