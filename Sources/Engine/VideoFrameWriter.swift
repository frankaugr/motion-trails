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
    private var frameIndex: Int64 = 0

    init(outputURL: URL, size: CGSize, frameRate: Int) throws {
        renderSize = size
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

    /// Renders a `CIImage` into a pooled pixel buffer (the allocation-heavy Core Image / Metal
    /// half of writing a frame) and returns it, ready to be appended.
    ///
    /// This is deliberately split from `append`: the engine calls it inside a per-frame
    /// `autoreleasepool` so the transient Metal textures / IOSurfaces this render spawns are
    /// reclaimed every frame instead of piling up across a long clip, while the async `append`
    /// stays outside the pool (you can't suspend across an `autoreleasepool` body).
    ///
    /// The render is a straight orientation passthrough: `CIContext.render(_:to:)` preserves the
    /// image's visual orientation into the buffer, and `VideoFrameReader` has already normalized
    /// every frame upright via `preferredTransform`. (There is deliberately **no** vertical flip
    /// here — an earlier one inverted every export; see the coordinate note in CLAUDE.md.)
    func makeFrameBuffer(_ image: CIImage, context: CIContext) throws -> CVPixelBuffer {
        guard let pool = adaptor.pixelBufferPool else { throw VideoIOError.cannotStartWriting }

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard let buffer = pixelBuffer else { throw VideoIOError.cannotStartWriting }

        let renderRect = CGRect(origin: .zero, size: renderSize)
        context.render(image, to: buffer, bounds: renderRect,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return buffer
    }

    /// Appends a buffer produced by `makeFrameBuffer` at the next fixed-rate presentation time,
    /// waiting for the encoder to drain if it has fallen behind.
    func append(_ buffer: CVPixelBuffer) async throws {
        try await waitUntilReady()
        let pts = CMTimeMultiply(frameDuration, multiplier: Int32(truncatingIfNeeded: frameIndex))
        guard adaptor.append(buffer, withPresentationTime: pts) else {
            throw VideoIOError.writerFailed(writer.error)
        }
        frameIndex += 1
    }

    func finish() async throws {
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        if writer.status != .completed {
            throw VideoIOError.writerFailed(writer.error)
        }
    }

    /// Spins until the encoder can take more data — but bails the moment the writer enters
    /// `.failed`, so a codec/disk error surfaces as a thrown error instead of an infinite loop and
    /// a permanently-hung progress bar. A cancelled render also breaks out via `Task.sleep`.
    private func waitUntilReady() async throws {
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed { throw VideoIOError.writerFailed(writer.error) }
            try await Task.sleep(nanoseconds: 2_000_000) // 2 ms
        }
        if writer.status == .failed { throw VideoIOError.writerFailed(writer.error) }
    }
}
