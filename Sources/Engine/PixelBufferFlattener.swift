import CoreImage
import CoreVideo

/// Flattens a lazily-evaluated `CIImage` filter graph into a concrete, GPU-resident image by
/// rendering it into a reusable pool of IOSurface-backed pixel buffers.
///
/// The engine must "flatten" the accumulator and age map every (snapshot) frame so the compositing
/// graph doesn't grow one filter deeper per frame. The previous approach went through
/// `CIContext.createCGImage` → `CIImage(cgImage:)`, which copies pixels into CPU-backed CGImage
/// storage and forces Core Image to re-upload them as a texture on next use — a GPU→CPU→GPU
/// round-trip per flatten. Rendering into a pooled `CVPixelBuffer` instead keeps the result on the
/// GPU (zero-copy via IOSurface) and recycles buffers, eliminating the readback and the per-frame
/// allocation churn. This mirrors what `VideoFrameWriter` already does for the encode path.
///
/// The render and the returned image both use the supplied color space (the engine passes its
/// context's working color space) so repeatedly feeding the flattened accumulator back in is a
/// color-space identity and the trail can't drift over hundreds of frames.
final class PixelBufferFlattener {
    private let colorSpace: CGColorSpace
    private let pool: CVPixelBufferPool?

    init(size: CGSize, colorSpace: CGColorSpace) {
        self.colorSpace = colorSpace
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        self.pool = pool
    }

    /// Renders `image` over `rect` into a pooled buffer and returns a GPU-backed `CIImage` of it.
    /// Falls back to the input image if a buffer can't be vended (so the pipeline still produces a
    /// frame, just without the flatten). `rect` is expected to be origin-anchored at (0,0), matching
    /// the engine's working space.
    func flatten(_ image: CIImage, rect: CGRect, context: CIContext) -> CIImage {
        guard let pool else { return image }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard let buffer = pixelBuffer else { return image }
        context.render(image, to: buffer, bounds: rect, colorSpace: colorSpace)
        return CIImage(cvPixelBuffer: buffer, options: [.colorSpace: colorSpace])
            .cropped(to: rect)
    }
}
