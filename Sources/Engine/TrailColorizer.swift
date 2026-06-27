import CoreImage
import CoreImage.CIFilterBuiltins

/// Colors the trail by age (spec §8 creative color trails). The engine's grayscale colour-age map
/// (1 = just written, decaying toward 0 at the gradient-speed rate) is mapped through a gradient so
/// the trail's hue encodes recency — fresh marks take the user's "newest" colour and shift toward
/// the "oldest" colour as they age. The live preview lerps the same endpoints per layer so its tint
/// matches the engine's colour map exactly.
struct TrailColorizer {
    private let gradient: CIImage

    init(oldest: CIColor, newest: CIColor) {
        let ramp = CIFilter.linearGradient()
        ramp.point0 = CGPoint(x: 0, y: 0)
        ramp.point1 = CGPoint(x: 256, y: 0)
        ramp.color0 = oldest
        ramp.color1 = newest
        gradient = (ramp.outputImage ?? CIImage.empty())
            .cropped(to: CGRect(x: 0, y: 0, width: 256, height: 1))
    }

    /// Maps each pixel of `ageMap` (grayscale recency) through the age gradient.
    func colorize(_ ageMap: CIImage) -> CIImage {
        let map = CIFilter.colorMap()
        map.inputImage = ageMap
        map.gradientImage = gradient
        return (map.outputImage ?? ageMap).cropped(to: ageMap.extent)
    }
}

extension RenderSettings.GradientColor {
    var ciColor: CIColor { CIColor(red: red, green: green, blue: blue) }
}
