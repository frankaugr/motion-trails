import CoreImage

/// Rasterizes the user's ignore-region rectangles (spec §9.3) into a grayscale "keep" mask:
/// 1 (white) outside the regions, 0 (black) inside. The engine multiplies the motion mask by
/// this so excluded areas (waving trees, water, shadows) never register as motion.
///
/// Built natively in Core Image so it aligns with the engine's processing-space frames. The
/// engine's CI space is vertically mirrored relative to the displayed video (the writer flips
/// rows on encode), so a normalized rect's `minY` maps straight onto the CI `y` — no flip here —
/// which lands the exclusion at the matching position once displayed.
enum IgnoreMaskBuilder {
    static func keepMask(regions: [CGRect], size: CGSize) -> CIImage? {
        guard !regions.isEmpty else { return nil }
        let bounds = CGRect(origin: .zero, size: size)
        var image = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: bounds)
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0))

        for region in regions {
            let w = region.width * size.width
            let h = region.height * size.height
            let x = region.minX * size.width
            let y = region.minY * size.height
            let pixelRect = CGRect(x: x, y: y, width: w, height: h).integral
            image = black.cropped(to: pixelRect).composited(over: image)
        }
        return image.cropped(to: bounds)
    }
}
