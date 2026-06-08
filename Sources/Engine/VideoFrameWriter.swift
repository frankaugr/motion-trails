import AVFoundation
import CoreImage
import CoreVideo

/// Encodes a sequence of `CIImage` frames into a 1080p-class H.264 MP4 (spec §10.4, §23).
///
/// Frames are rendered into pooled BGRA pixel buffers via the shared `CIContext` and
/// appended at a fixed output frame rate, producing constant-timed output regardless of
/// the source's frame timing.
final class VideoFrameWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let frameDuration: CMTime
    private let renderSize: CGSize
    private let videoBufferTransform: CGAffineTransform
    private var frameIndex: Int64 = 0

    init(outputURL: URL, size: CGSize, frameRate: Int) throws {
        renderSize = size
        videoBufferTransform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        // ~6 bits/pixel/frame heuristic gives roughly 12 Mbps at 1080p, fine for social MP4.
        let bitrate = Int(size.width * size.height) * 6
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: true
            ]
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false

        let bufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: bufferAttributes
        )

        guard writer.canAdd(input) else { throw VideoIOError.cannotStartWriting }
        writer.add(input)

        frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, frameRate)))
    }

    func start() throws {
        guard writer.startWriting() else { throw VideoIOError.cannotStartWriting }
        writer.startSession(atSourceTime: .zero)
    }

    /// Renders a `CIImage` into a pooled buffer and appends it as the next output frame.
    ///
    /// The encoded buffer is vertically flipped because Core Image's working coordinate space
    /// has y=0 at the bottom, while video playback treats the first encoded row as the top.
    /// The returned image maps that buffer back into the engine's normal coordinate space so
    /// it can be reused as the next accumulator without growing the compositing graph.
    @discardableResult
    func append(_ image: CIImage, context: CIContext) async throws -> CIImage {
        guard let pool = adaptor.pixelBufferPool else { throw VideoIOError.cannotStartWriting }

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard let buffer = pixelBuffer else { throw VideoIOError.cannotStartWriting }

        let renderRect = CGRect(origin: .zero, size: renderSize)
        let imageForEncoding = image.transformed(by: videoBufferTransform)
        context.render(
            imageForEncoding,
            to: buffer,
            bounds: renderRect,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )

        await waitUntilReady()
        let pts = CMTimeMultiply(frameDuration, multiplier: Int32(truncatingIfNeeded: frameIndex))
        adaptor.append(buffer, withPresentationTime: pts)
        frameIndex += 1
        return CIImage(cvPixelBuffer: buffer)
            .transformed(by: videoBufferTransform)
            .cropped(to: renderRect)
    }

    func finish() async {
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
    }

    private func waitUntilReady() async {
        while !input.isReadyForMoreMediaData {
            try? await Task.sleep(nanoseconds: 2_000_000) // 2 ms
        }
    }
}
