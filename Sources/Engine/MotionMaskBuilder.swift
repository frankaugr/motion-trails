import CoreImage
import CoreImage.CIFilterBuiltins

/// Builds a soft motion mask for one frame by comparing it against the static background
/// (spec §11.4). The returned image carries the mask in its **alpha** channel — alpha 1
/// where the subject moved, 0 where the scene is static — which is what `CIBlendWithMask`
/// consumes during compositing.
struct MotionMaskBuilder {

    func makeMask(current: CIImage, background: CIImage, settings: RenderSettings) -> CIImage {
        let extent = current.extent

        // 1) Per-channel |current - background|. Difference *blend* (not absolute-difference)
        //    keeps the result opaque (alpha = 1), so the premultiplied-alpha morphology and
        //    threshold passes below operate on the real RGB magnitude.
        let diff = CIFilter.differenceBlendMode()
        diff.inputImage = current
        diff.backgroundImage = background

        // 2) Collapse RGB change to a single magnitude (max channel) — a strong shift in any
        //    one channel counts as motion.
        let magnitude = CIFilter.maximumComponent()
        magnitude.inputImage = diff.outputImage
        let magImage = magnitude.outputImage ?? current

        // 3) Threshold to a hard mask; sensitivity drives the cutoff.
        let threshold = CIFilter.colorThreshold()
        threshold.inputImage = magImage
        threshold.threshold = Float(settings.differenceThreshold)

        // 4) Opening (erode -> dilate) removes speckle and sub-minimum regions.
        let radius = Float(settings.morphologyRadius)
        let opened = dilate(erode(threshold.outputImage, radius: radius), radius: radius)

        // 5) Closing (dilate -> erode) fills small holes inside the subject.
        let closeRadius = max(1, radius * 0.75)
        let closed = erode(dilate(opened, radius: closeRadius), radius: closeRadius)

        // 6) Light feather so composited subject edges aren't aliased (edge preservation, §11.4).
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = closed
        blur.radius = 1.0

        // 7) Move the grayscale mask into the alpha channel for CIBlendWithMask.
        let maskToAlpha = CIFilter.maskToAlpha()
        maskToAlpha.inputImage = blur.outputImage

        let result = maskToAlpha.outputImage ?? magImage
        // Morphology and blur enlarge the extent; crop back to the frame.
        return result.cropped(to: extent)
    }

    /// Shrinks bright regions (`CIMorphologyMinimum`).
    private func erode(_ image: CIImage?, radius: Float) -> CIImage? {
        guard let image else { return nil }
        let f = CIFilter.morphologyMinimum()
        f.inputImage = image
        f.radius = radius
        return f.outputImage
    }

    /// Grows bright regions (`CIMorphologyMaximum`).
    private func dilate(_ image: CIImage?, radius: Float) -> CIImage? {
        guard let image else { return nil }
        let f = CIFilter.morphologyMaximum()
        f.inputImage = image
        f.radius = radius
        return f.outputImage
    }
}
