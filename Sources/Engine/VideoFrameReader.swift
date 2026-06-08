import AVFoundation
import CoreImage
import CoreVideo

enum VideoIOError: Error, LocalizedError {
    case noVideoTrack
    case cannotStartReading
    case cannotStartWriting
    case readerFailed(Error?)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "The selected file has no video track."
        case .cannotStartReading: return "Could not start reading the source video."
        case .cannotStartWriting: return "Could not start writing the output video."
        case .readerFailed(let e): return "Reading the source video failed: \(e?.localizedDescription ?? "unknown error")."
        }
    }
}

/// Describes the source video track and the orientation-normalized working space.
struct VideoInfo {
    /// Raw decoded pixel dimensions, before `preferredTransform`.
    let naturalSize: CGSize
    /// Track transform that maps raw pixels into display orientation.
    let preferredTransform: CGAffineTransform
    let nominalFrameRate: Float
    let duration: CMTime

    /// Display-oriented, even-rounded size the pipeline and writer operate in.
    var orientedSize: CGSize {
        let rect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        // H.264 requires even dimensions.
        let w = (Int(abs(rect.width).rounded())) & ~1
        let h = (Int(abs(rect.height).rounded())) & ~1
        return CGSize(width: max(w, 2), height: max(h, 2))
    }

    /// Estimated number of frames, for progress reporting.
    var estimatedFrameCount: Int {
        max(1, Int((duration.seconds * Double(nominalFrameRate)).rounded()))
    }
}

/// Sequentially decodes a source video into orientation-normalized `CIImage` frames.
///
/// Frames are decoded as BGRA, Metal-compatible buffers and returned already rotated
/// into display orientation with their origin at (0,0), so downstream filters can treat
/// every frame as if it were captured upright (spec §11.1).
final class VideoFrameReader {
    let info: VideoInfo

    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let orientationTransform: CGAffineTransform

    init(url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoIOError.noVideoTrack
        }

        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let frameRate = try await track.load(.nominalFrameRate)
        let duration = try await asset.load(.duration)

        let info = VideoInfo(
            naturalSize: naturalSize,
            preferredTransform: transform,
            nominalFrameRate: frameRate > 0 ? frameRate : 30,
            duration: duration
        )
        self.info = info

        // Build a transform that rotates raw pixels into display orientation and
        // shifts the result back to a (0,0) origin.
        let rotated = CGRect(origin: .zero, size: naturalSize).applying(transform)
        self.orientationTransform = transform.concatenating(
            CGAffineTransform(translationX: -rotated.minX, y: -rotated.minY)
        )

        reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
    }

    /// Begins decoding. Must be called before `nextFrame()`.
    func start() throws {
        guard reader.startReading() else {
            throw VideoIOError.cannotStartReading
        }
    }

    /// Returns the next frame as an orientation-normalized `CIImage`, or `nil` at end of stream.
    func nextFrame() throws -> CIImage? {
        guard let sample = output.copyNextSampleBuffer() else {
            if reader.status == .failed { throw VideoIOError.readerFailed(reader.error) }
            return nil
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return nil }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard !orientationTransform.isIdentity else { return image }
        return image.transformed(by: orientationTransform)
    }
}
