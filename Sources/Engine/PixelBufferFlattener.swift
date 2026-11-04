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
/// **Pick the storage by what the buffer holds** — use the `image` / `scalar` factories rather than
/// the raw initializer:
/// - `image(size:)` — 8-bit BGRA, **sRGB-encoded**. For pictures: decoded frames, mask proxies,
///   trail accumulators, preview layers. 8 bits must be gamma-encoded: Core Image's working space
///   is *linear*, and 8-bit linear storage leaves the darkest fifth of the tonal range only ~9
///   levels (vs 51), posterizing shadows in every flattened frame.
/// - `scalar(size:)` — 16-bit **half-float**, linear. For per-pixel numeric maps that are decayed
///   and re-flattened every frame (the fade / colour age maps). At 8 bits, `round(q · decay) == q`
///   once `q < 0.5 / (1 − decay)`, so a long fade froze at a permanent residual (≈20% opacity for
///   a 10 s fade at 30 fps) instead of reaching zero; half-float keeps decaying exactly.
///
/// The render and the returned image use the same color space, so repeatedly feeding a flattened
/// buffer back in is a round-trip identity (encode∘decode returns the same 8-bit code) and the
/// trail can't drift over hundreds of frames.
final class PixelBufferFlattener {
    private let colorSpace: CGColorSpace
    private let pool: CVPixelBufferPool?

    /// Gamma-encoded 8-bit colour storage (frames, proxies, accumulators, preview layers).
    static func image(size: CGSize) -> PixelBufferFlattener {
        PixelBufferFlattener(size: size,
                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                             pixelFormat: kCVPixelFormatType_32BGRA)
    }

    /// Linear half-float storage for scalar maps re-flattened every frame (fade / colour age).
    /// Uses the shared context's working space, so the flatten is a colour-space identity.
    static func scalar(size: CGSize) -> PixelBufferFlattener {
        let linear = SharedRender.ciContext.workingColorSpace
            ?? CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        return PixelBufferFlattener(size: size, colorSpace: linear,
                                    pixelFormat: kCVPixelFormatType_64RGBAHalf)
    }

    init(size: CGSize, colorSpace: CGColorSpace, pixelFormat: OSType = kCVPixelFormatType_32BGRA) {
        self.colorSpace = colorSpace
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
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
