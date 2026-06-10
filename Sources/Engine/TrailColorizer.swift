import CoreImage
import CoreImage.CIFilterBuiltins

/// Colors the trail by age (spec §8 creative color trails). The engine's grayscale age map
/// (1 = just written, decaying toward 0) is mapped through a gradient so the trail's hue encodes
/// recency — newer parts warm, older parts cool.
struct TrailColorizer {
    /// Gradient endpoints, shared with the live preview so its per-layer tint matches the
    /// engine's color map exactly.
    static let oldestColor = CIColor(red: 0.16, green: 0.30, blue: 0.92)   // oldest → blue
    static let newestColor = CIColor(red: 1.00, green: 0.55, blue: 0.05)   // newest → orange

    private let gradient: CIImage

    init() {
        let ramp = CIFilter.linearGradient()
        ramp.point0 = CGPoint(x: 0, y: 0)
        ramp.point1 = CGPoint(x: 256, y: 0)
        ramp.color0 = Self.oldestColor
        ramp.color1 = Self.newestColor
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
