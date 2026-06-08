import AVFoundation
import CoreImage

/// Builds the static background reference (spec §11.2) as a per-pixel temporal **median** of
/// frames sampled across the clip.
///
/// A single frame is fragile (clips often open on a black fade-in, and any one frame of a busy
/// scene contains the moving subjects). A mean is fragile too — fade-in/out frames drag it dark.
/// The per-pixel median is robust: at each pixel the static scene is the majority value over
/// time, so transient subjects and a minority of dark fade frames drop out, leaving a clean plate.
struct BackgroundEstimator {
    /// Frames folded into the median — caps cost and memory on long clips.
    private let maxSamples = 19
    /// Frames dimmer than this mean luma (fade-in/out) are not sampled.
    private let darkLumaCutoff = 0.06

    func estimate(url: URL, cropRect: CGRect) async throws -> CIImage {
        let context = SharedRender.ciContext
        let width = Int(cropRect.width)
        let height = Int(cropRect.height)
        let rowBytes = width * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        let reader = try await VideoFrameReader(url: url)
        try reader.start()

        let stride = max(1, reader.info.estimatedFrameCount / maxSamples)
        var samples: [[UInt8]] = []
        var index = 0

        while samples.count < maxSamples, let raw = try reader.nextFrame() {
            defer { index += 1 }
            guard index % stride == 0 else { continue }
            let frame = raw.cropped(to: cropRect)
            guard Self.meanLuma(frame, rect: cropRect, context: context) >= darkLumaCutoff else { continue }

            var buffer = [UInt8](repeating: 0, count: rowBytes * height)
            buffer.withUnsafeMutableBytes { ptr in
                context.render(frame, toBitmap: ptr.baseAddress!, rowBytes: rowBytes,
                               bounds: cropRect, format: .RGBA8, colorSpace: colorSpace)
            }
            samples.append(buffer)
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
