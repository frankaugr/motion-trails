import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Synthesizes the bundled-by-construction demo clip: a static gradient sky with a few fast
/// "birds" (soft dark dots) crossing it. First-run onboarding turns it into a demo project so a
/// new user sees a successful trail render in under a minute, without needing the right footage.
///
/// The clip is deliberately ideal input for the engine — perfectly static background, high
/// contrast, fast subjects — and is also handy as a deterministic source for the headless
/// verification harness (it exercises the writer, reader, estimator and detector end to end).
struct SampleClipFactory {
    let size = CGSize(width: 720, height: 1280)
    let fps = 30
    let durationSeconds = 5.0

    private struct Bird {
        let baseY: CGFloat      // flight altitude (fraction of height)
        let amplitude: CGFloat  // sine bob amplitude in px
        let wavelength: Double  // bobs per crossing
        let start: Double       // takeoff time (fraction of clip)
        let flight: Double      // seconds to cross the frame
        let radius: CGFloat     // dot radius in px
    }

    private let birds: [Bird] = [
        Bird(baseY: 0.72, amplitude: 26, wavelength: 2.2, start: 0.02, flight: 2.6, radius: 11),
        Bird(baseY: 0.58, amplitude: 34, wavelength: 1.6, start: 0.18, flight: 3.4, radius: 14),
        Bird(baseY: 0.45, amplitude: 20, wavelength: 2.8, start: 0.40, flight: 2.2, radius: 9),
        Bird(baseY: 0.32, amplitude: 30, wavelength: 1.9, start: 0.55, flight: 3.0, radius: 12)
    ]

    /// Renders the demo clip to a temp MP4 and returns its URL. Cancellable.
    func makeClip() async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sample-\(UUID().uuidString).mp4")
        let writer = try VideoFrameWriter(outputURL: url, size: size, frameRate: fps)
        try writer.start()

        let context = SharedRender.ciContext
        let rect = CGRect(origin: .zero, size: size)
        let flattener = PixelBufferFlattener(size: size, colorSpace: context.workingColorSpace ?? CGColorSpaceCreateDeviceRGB())
        let sky = flattener.flatten(makeSky(rect: rect), rect: rect, context: context)

        let frameCount = Int(durationSeconds * Double(fps))
        for frame in 0..<frameCount {
            try Task.checkCancellation()
            let t = Double(frame) / Double(fps)
            // CI/Metal temporaries are reclaimed per frame; the async append stays outside the
            // pool (same split the render engine uses).
            let buffer = try autoreleasepool {
                var composite = sky
                for bird in birds {
                    if let dot = birdDot(bird, at: t) {
                        composite = dot.composited(over: composite)
                    }
                }
                return try writer.makeFrameBuffer(composite.cropped(to: rect), context: context)
            }
            await writer.append(buffer)
        }
        await writer.finish()
        return url
    }

    /// Vertical dawn-sky gradient: deep blue up top, pale warm light at the horizon.
    private func makeSky(rect: CGRect) -> CIImage {
        let ramp = CIFilter.linearGradient()
        ramp.point0 = CGPoint(x: 0, y: 0)                       // visual bottom (y-up space)
        ramp.point1 = CGPoint(x: 0, y: rect.height)
        ramp.color0 = CIColor(red: 0.93, green: 0.88, blue: 0.80)
        ramp.color1 = CIColor(red: 0.30, green: 0.48, blue: 0.72)
        return (ramp.outputImage ?? CIImage(color: ramp.color1)).cropped(to: rect)
    }

    /// One bird at time `t`: a soft-edged dark dot on a sine flight path, or `nil` if it isn't
    /// in the air yet / has crossed out of frame.
    private func birdDot(_ bird: Bird, at t: Double) -> CIImage? {
        let takeoff = bird.start * durationSeconds
        let progress = (t - takeoff) / bird.flight
        guard progress >= 0, progress <= 1 else { return nil }

        let margin = bird.radius * 3
        let x = -margin + (size.width + 2 * margin) * CGFloat(progress)
        let bob = bird.amplitude * CGFloat(sin(progress * bird.wavelength * 2 * .pi))
        let y = size.height * bird.baseY + bob

        let dot = CIFilter.radialGradient()
        dot.center = CGPoint(x: x, y: y)
        dot.radius0 = Float(bird.radius * 0.6)
        dot.radius1 = Float(bird.radius)
        dot.color0 = CIColor(red: 0.07, green: 0.09, blue: 0.13, alpha: 1)
        dot.color1 = CIColor(red: 0.07, green: 0.09, blue: 0.13, alpha: 0)
        let bounds = CGRect(x: x - bird.radius, y: y - bird.radius,
                            width: bird.radius * 2, height: bird.radius * 2)
        return dot.outputImage?.cropped(to: bounds)
    }
}
