import CoreImage
import CoreImage.CIFilterBuiltins

/// Renders the free-tier watermark (spec §7.6, §13) as a `CIImage` the engine composites into
/// a corner of each export frame. Uses Core Image's native text generator so it shares the
/// engine's coordinate space (no CGImage y-flip) and builds in the headless macOS harness.
struct WatermarkRenderer {
    var text: String = "Motion Trails"

    /// Builds the watermark — white text over a soft dark halo for legibility on bright skies —
    /// with its extent anchored at the origin. Returns `nil` if generation fails.
    func makeWatermark(outputSize: CGSize) -> CIImage? {
        let fontSize = max(16, outputSize.height * 0.03)

        let generator = CIFilter.textImageGenerator()
        generator.text = text
        generator.fontName = "HelveticaNeue-Bold"
        generator.fontSize = Float(fontSize)
        generator.scaleFactor = 1
        generator.padding = Float(fontSize * 0.5)
        guard let textImage = generator.outputImage else { return nil }
        let box = textImage.extent

        // Dark, blurred copy behind the text for contrast on light backgrounds.
        let blackText = CIFilter.colorMatrix()
        blackText.inputImage = textImage
        blackText.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        blackText.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        blackText.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        blackText.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)

        let halo = CIFilter.gaussianBlur()
        halo.inputImage = blackText.outputImage
        halo.radius = Float(fontSize * 0.18)

        let composite = textImage.composited(over: halo.outputImage ?? textImage)
        // Anchor back to (0,0) — the blur grows the extent into negative space.
        return composite
            .cropped(to: box)
            .transformed(by: CGAffineTransform(translationX: -box.minX, y: -box.minY))
    }

    /// Composites a prepared watermark into the bottom-right of the *displayed* video.
    ///
    /// The engine's CI space is vertically mirrored vs. the encoded frame (the writer flips rows
    /// on encode, which leaves the pre-flipped source content upright). A freshly generated overlay
    /// is upright in CI, so we **pre-flip it vertically** here — the writer's flip then lands the
    /// text upright — and place it at CI-top so it ends up at the visual bottom.
    func apply(_ watermark: CIImage, to image: CIImage, outputRect: CGRect) -> CIImage {
        let pad = outputRect.height * 0.02
        let x = outputRect.maxX - watermark.extent.width - pad
        let y = outputRect.maxY - watermark.extent.height - pad
        let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: watermark.extent.height)
        let placed = watermark
            .transformed(by: flip)
            .transformed(by: CGAffineTransform(translationX: x, y: y))
        return placed.composited(over: image).cropped(to: outputRect)
    }
}
