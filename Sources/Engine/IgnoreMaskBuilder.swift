import CoreImage

/// Rasterizes the user's ignore-region rectangles (spec §9.3) into a grayscale "keep" mask:
/// 1 (white) outside the regions, 0 (black) inside. The engine multiplies the motion mask by
/// this so excluded areas (waving trees, water, shadows) never register as motion.
///
/// Built natively in Core Image so it aligns with the engine's processing-space frames. Regions
/// arrive normalized with a **top-left origin** (`MaskEditorView`, y-down), but the engine's CI
/// space is **y-up** (origin bottom-left) and the encode is a straight passthrough — no writer
/// flip to compensate — so we flip the rect's `y` here: a region's top-left `minY` becomes the
/// CI rect's lower edge at `(1 - minY - height) * H`. Without this flip the exclusion lands
/// vertically mirrored (e.g. a box over the water would mask the sky).
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
            let y = (1 - region.minY - region.height) * size.height   // top-left UI origin → CI y-up
            let pixelRect = CGRect(x: x, y: y, width: w, height: h).integral
            image = black.cropped(to: pixelRect).composited(over: image)
        }
        return image.cropped(to: bounds)
    }
}
