import CoreImage
import CoreImage.CIFilterBuiltins

/// Rasterizes the user's ignore regions (spec §9.3) — rectangles and freehand brush strokes —
/// into a grayscale "keep" mask: 1 (white) outside the regions, 0 (black) inside, with a small
/// feathered edge. The engine multiplies the motion mask by this so excluded areas (waving trees,
/// water, shadows) never register as motion, and the feather lets trails fade across the boundary
/// instead of hard-clipping against it.
///
/// Geometry arrives normalized with a **top-left origin** (`MaskEditorView`, y-down), but both the
/// CGBitmapContext used here and the engine's CI space are **y-up** (origin bottom-left) and the
/// encode is a straight passthrough — no writer flip to compensate — so we flip `y` here: a
/// region's top-left `minY` becomes the y-up rect's lower edge at `(1 - minY - height) * H`.
/// Without this flip the exclusion lands vertically mirrored (e.g. a box over the water would
/// mask the sky). Stroke radii are normalized to the image **width** (see
/// `RenderSettings.IgnoreStroke`).
///
/// The mask is built **once** per render/prepare and flattened to a concrete bitmap before being
/// returned, so the per-frame multiply samples pixels rather than re-evaluating the blur graph —
/// the feather adds no per-frame cost.
enum IgnoreMaskBuilder {
    /// Feather sigma as a fraction of the image width (≈5 px at 1920) — proportional so the
    /// preview's proxy-scale mask softens identically to the full-res render.
    private static let featherFraction: CGFloat = 0.0025

    static func keepMask(regions: [CGRect],
                         strokes: [RenderSettings.IgnoreStroke] = [],
                         size: CGSize) -> CIImage? {
        guard !(regions.isEmpty && strokes.isEmpty) else { return nil }
        let width = max(2, Int(size.width.rounded()))
        let height = max(2, Int(size.height.rounded()))
        guard let cg = CGContext(data: nil, width: width, height: height,
                                 bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpaceCreateDeviceGray(),
                                 bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        cg.setFillColor(gray: 1, alpha: 1)
        cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
        cg.setFillColor(gray: 0, alpha: 1)

        for region in regions {
            cg.fill(CGRect(x: region.minX * size.width,
                           y: (1 - region.minY - region.height) * size.height,   // top-left UI origin → y-up
                           width: region.width * size.width,
                           height: region.height * size.height))
        }

        cg.setStrokeColor(gray: 0, alpha: 1)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        for stroke in strokes {
            let points = stroke.points.map {
                CGPoint(x: $0.x * size.width, y: (1 - $0.y) * size.height)
            }
            guard let first = points.first else { continue }
            let radius = max(1, stroke.radius * size.width)
            if points.count == 1 {
                cg.fillEllipse(in: CGRect(x: first.x - radius, y: first.y - radius,
                                          width: radius * 2, height: radius * 2))
            } else {
                cg.setLineWidth(radius * 2)
                cg.addLines(between: points)
                cg.strokePath()
            }
        }

        guard let rasterized = cg.makeImage() else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = CIImage(cgImage: rasterized).clampedToExtent()
        blur.radius = Float(max(0.6, featherFraction * size.width))
        let feathered = (blur.outputImage ?? CIImage(cgImage: rasterized)).cropped(to: bounds)
        // Flatten the blur once so per-frame consumers sample a concrete bitmap.
        guard let flat = SharedRender.ciContext.createCGImage(feathered, from: bounds) else {
            return CIImage(cgImage: rasterized)
        }
        return CIImage(cgImage: flat)
    }
}
