import CoreImage
import CoreImage.CIFilterBuiltins

/// Composites moving pixels into the accumulator (spec §9.2, §11.5).
///
/// Stateless on purpose: the engine owns the accumulator (so it can flatten it to a pixel
/// buffer each frame). For every frame, moving pixels from the current frame are written into
/// the accumulator; static pixels keep whatever was there.
///
/// - `.replacement` (default): the current pixel overwrites the accumulator, so a later subject
///   cleanly replaces an earlier one at the same pixel.
/// - `.overlay` (premium): the current pixel is half-blended with the accumulator, so overlapping
///   passes layer into a softer, ghosted trail.
struct TrailCompositor {

    func compose(current: CIImage, over accumulator: CIImage, mask: CIImage,
                 mode: RenderSettings.TrailMode = .replacement) -> CIImage {
        let foreground: CIImage
        switch mode {
        case .replacement:
            foreground = current
        case .overlay:
            foreground = setAlpha(current, 0.5).composited(over: accumulator)
        }

        let blend = CIFilter.blendWithMask()
        blend.inputImage = foreground          // written where mask alpha = 1
        blend.backgroundImage = accumulator    // preserved where mask alpha = 0
        blend.maskImage = mask

        let extent = accumulator.extent
        return (blend.outputImage ?? accumulator).cropped(to: extent)
    }

    private func setAlpha(_ image: CIImage, _ alpha: CGFloat) -> CIImage {
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = image
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        matrix.biasVector = CIVector(x: 0, y: 0, z: 0, w: alpha)
        return matrix.outputImage ?? image
    }
}
