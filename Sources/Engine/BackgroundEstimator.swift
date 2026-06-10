import AVFoundation
import CoreImage

/// Builds the static background reference (spec §11.2) as a per-pixel temporal **median** of
/// frames sampled across the clip.
///
/// A single frame is fragile (clips often open on a black fade-in, and any one frame of a busy
/// scene contains the moving subjects). A mean is fragile too — fade-in/out frames drag it dark.
/// The per-pixel median is robust: at each pixel the static scene is the majority value over
/// time, so transient subjects and a minority of dark fade frames drop out, leaving a clean plate.
///
/// Sampling is **random access** via `AVAssetImageGenerator` (~19 seeks), not a sequential decode
/// of every frame — on a long clip that cuts the pre-render "analyzing" pass from a full decode
/// to a handful of keyframe-adjacent reads. A small time tolerance lets the generator snap to
/// nearby sync frames for speed; the median is insensitive to the exact frames chosen.
struct BackgroundEstimator {
    /// Frames folded into the median — caps cost and memory on long clips.
    private let maxSamples = 19
    /// Frames dimmer than this mean luma (fade-in/out) are not sampled.
    private let darkLumaCutoff = 0.06

    /// `progress` reports 0…1 across the sampling pass so the caller can surface an
    /// "analyzing scene" stage instead of sitting at 0%.
    func estimate(url: URL, cropRect: CGRect,
                  progress: (@Sendable (Double) -> Void)? = nil) async throws -> CIImage {
        let context = SharedRender.ciContext
        let width = Int(cropRect.width)
        let height = Int(cropRect.height)
        let rowBytes = width * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        let asset = AVURLAsset(url: url)
        let durationSeconds = try await asset.load(.duration).seconds
        guard durationSeconds > 0 else { throw VideoIOError.readerFailed(nil) }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Snapping to nearby sync frames keeps each request to ~one GOP of decode work. The exact
        // frame doesn't matter to a median, only that the samples spread across the clip.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)

        // Evenly spaced inside [2%, 98%] of the clip — the margins dodge fade-in/out frames the
        // luma check would reject anyway.
        let times = (0..<maxSamples).map { i -> CMTime in
            let fraction = 0.02 + 0.96 * Double(i) / Double(max(1, maxSamples - 1))
            return CMTime(seconds: durationSeconds * fraction, preferredTimescale: 600)
        }

        var samples: [[UInt8]] = []
        for (index, time) in times.enumerated() {
            guard let cgImage = try? await generator.image(at: time).image else { continue }
            // Render into the engine's working geometry inside a pool so each sample's transient
            // CI/Metal allocations are reclaimed before the next seek.
            let sample: [UInt8]? = autoreleasepool {
                var frame = CIImage(cgImage: cgImage)
                let sx = cropRect.width / CGFloat(cgImage.width)
                let sy = cropRect.height / CGFloat(cgImage.height)
                if sx != 1 || sy != 1 {
                    frame = frame.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                }
                frame = frame.cropped(to: cropRect)
                guard Self.meanLuma(frame, rect: cropRect, context: context) >= darkLumaCutoff else { return nil }

                var buffer = [UInt8](repeating: 0, count: rowBytes * height)
                buffer.withUnsafeMutableBytes { ptr in
                    context.render(frame, toBitmap: ptr.baseAddress!, rowBytes: rowBytes,
                                   bounds: cropRect, format: .RGBA8, colorSpace: colorSpace)
                }
                return buffer
            }
            if let sample { samples.append(sample) }
            progress?(Double(index + 1) / Double(maxSamples))
        }

        guard let first = samples.first else { throw VideoIOError.readerFailed(nil) }
        let n = samples.count
        if n == 1 {
            return CIImage(bitmapData: Data(first), bytesPerRow: rowBytes,
                           size: CGSize(width: width, height: height),
                           format: .RGBA8, colorSpace: colorSpace)
        }

        // Per-pixel, per-channel median across the sampled frames. The rows are independent and
        // each writes a disjoint slice of `output`, so the work is fanned out across cores with
        // `concurrentPerform` — the median is the single biggest one-time cost before the first
        // frame renders, and it's embarrassingly parallel.
        var output = [UInt8](repeating: 0, count: rowBytes * height)
        let mid = n / 2

        output.withUnsafeMutableBufferPointer { out in
            // Each iteration writes a disjoint row slice, so sharing the base pointer is safe.
            nonisolated(unsafe) let outBase = out.baseAddress!
            DispatchQueue.concurrentPerform(iterations: height) { row in
                var scratch = [UInt8](repeating: 0, count: n)
                let rowStart = row * rowBytes
                for x in 0..<width {
                    let base = rowStart + x * 4
                    for c in 0..<3 {
                        for k in 0..<n { scratch[k] = samples[k][base + c] }
                        scratch.sort()
                        outBase[base + c] = scratch[mid]
                    }
                    outBase[base + 3] = 255
                }
            }
        }

        return CIImage(bitmapData: Data(output), bytesPerRow: rowBytes,
                       size: CGSize(width: width, height: height),
                       format: .RGBA8, colorSpace: colorSpace)
    }

    /// Mean luminance of an image over `rect`, in 0...1.
    static func meanLuma(_ image: CIImage, rect: CGRect, context: CIContext) -> Double {
        let average = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: image,
            kCIInputExtentKey: CIVector(cgRect: rect)
        ])
        guard let output = average?.outputImage else { return 0 }
        var px = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &px, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return (0.299 * Double(px[0]) + 0.587 * Double(px[1]) + 0.114 * Double(px[2])) / 255.0
    }
}
