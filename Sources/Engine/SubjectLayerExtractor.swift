import CoreImage
import CoreImage.CIFilterBuiltins

/// Cuts the moving subject out of a frame (transparent everywhere else) by reusing the same
/// motion mask the renderer uses. Layering these cut-outs reproduces a replacement/overlay trail,
/// which lets the live preview recompose density without re-running the full pipeline.
struct SubjectLayerExtractor {
    private let maskBuilder = MotionMaskBuilder()

    /// Temporal cut-out: subject = what moves between `frame` and its neighbour samples
    /// (`earlier`/`later`). Matches the engine's temporal detection so the preview reflects the
    /// render. Pass `nil` for a missing neighbour (the sequence ends).
    func subjectLayer(frame: CIImage, earlier: CIImage?, later: CIImage?, settings: RenderSettings,
                      radiusScale: CGFloat = 1) -> CIImage {
        let mask = maskBuilder.makeMask(current: frame, earlier: earlier, later: later,
                                        settings: settings, radiusScale: radiusScale)
        return cutOut(frame, mask)
    }

    /// Legacy single-reference cut-out (vs. a static `background`). Retained for the headless harness.
    func subjectLayer(frame: CIImage, background: CIImage, settings: RenderSettings,
                      radiusScale: CGFloat = 1) -> CIImage {
        let mask = maskBuilder.makeMask(current: frame, background: background, settings: settings,
                                        radiusScale: radiusScale)
        return cutOut(frame, mask)
    }

    private func cutOut(_ frame: CIImage, _ mask: CIImage) -> CIImage {
        let blend = CIFilter.blendWithMask()
        blend.inputImage = frame
        blend.backgroundImage = CIImage.empty()   // transparent
        blend.maskImage = mask
        return (blend.outputImage ?? frame).cropped(to: frame.extent)
    }
}
