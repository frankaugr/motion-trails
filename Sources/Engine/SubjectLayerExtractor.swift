import CoreImage
import CoreImage.CIFilterBuiltins

/// Cuts the moving subject out of a frame (transparent everywhere else) by reusing the same
/// motion mask the renderer uses. Layering these cut-outs reproduces a replacement/overlay trail,
/// which lets the live preview recompose density without re-running the full pipeline.
struct SubjectLayerExtractor {
    private let maskBuilder = MotionMaskBuilder()

    func subjectLayer(frame: CIImage, background: CIImage, settings: RenderSettings,
                      radiusScale: CGFloat = 1) -> CIImage {
        let mask = maskBuilder.makeMask(current: frame, background: background, settings: settings,
                                        radiusScale: radiusScale)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = frame
        blend.backgroundImage = CIImage.empty()   // transparent
        blend.maskImage = mask
        return (blend.outputImage ?? frame).cropped(to: frame.extent)
    }
}
