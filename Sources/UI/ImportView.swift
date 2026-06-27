import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation
import CoreImage
import OSLog

let importLog = Logger(subsystem: "com.frank.motiontrails", category: "import")

/// Why an imported clip was rejected, with user-facing copy.
enum ImportError: LocalizedError {
    case noVideoTrack
    case tooLong(Double)
    case normalizationFailed

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "That file doesn't contain a video track. Pick a video clip and try again."
        case .tooLong(let seconds):
            return "That clip is \(Int(seconds.rounded())) seconds long. Please trim it to under \(Int(ClipImporter.maxDuration / 60)) minutes and try again."
        case .normalizationFailed:
            return "Couldn't prepare that clip for rendering. Try a different video."
        }
    }
}

/// Validates a picked clip and, when it's larger than the engine needs (oversized, HDR, or an
/// editing codec like ProRes), transcodes it to a 1080p-class SDR H.264 copy. The trail output is
/// already 1080p-class, so this loses nothing visible and keeps a 4K/HDR import from blowing the
/// memory budget across the estimator, render window and parallax planes (the §4K-OOM fix).
enum ClipImporter {
    /// Longest edge the working pipeline keeps; anything larger is downscaled on import.
    static let maxLongEdge: CGFloat = 1920
    /// Import length ceiling (memory + render time grow with clip length).
    static let maxDuration: Double = 120

    /// Returns a URL to use as the project source — the original when it's already small enough,
    /// otherwise a freshly transcoded temp file the caller is responsible for cleaning up.
    static func normalize(_ url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)

        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            throw ImportError.noVideoTrack
        }

        let duration = (try? await asset.load(.duration).seconds) ?? 0
        if duration > maxDuration + 1 { throw ImportError.tooLong(duration) }

        let naturalSize = (try? await track.load(.naturalSize)) ?? .zero
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        let oriented = naturalSize.applying(transform)
        let longEdge = max(abs(oriented.width), abs(oriented.height))

        let descriptions = (try? await track.load(.formatDescriptions)) ?? []
        let needsNormalize = longEdge > maxLongEdge || isHDR(descriptions)
        guard needsNormalize else { return url }

        do {
            return try await reEncodeDownscaled(url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            importLog.error("normalize re-encode failed: \(error.localizedDescription, privacy: .public)")
            throw ImportError.normalizationFailed
        }
    }

    /// Re-encodes the clip through the engine's OWN read/write path (`VideoFrameReader` ->
    /// downscale -> `VideoFrameWriter`), downscaled to <= `maxLongEdge` and tone-mapped to SDR.
    /// This is deliberately *not* `AVAssetExportSession`: that rotates portrait (90°/270°) clips
    /// 180° relative to how `VideoFrameReader` orients them — its render space is y-down while the
    /// engine's is y-up — so imported 4K/HDR portrait clips came out upside-down. Reusing the
    /// render pipeline makes orientation identical to a normal render by construction.
    private static func reEncodeDownscaled(_ url: URL) async throws -> URL {
        let context = SharedRender.ciContext
        let reader = try await VideoFrameReader(url: url)
        try reader.start()
        let oriented = reader.info.orientedSize
        let scale = min(1, maxLongEdge / max(oriented.width, oriented.height))
        func even(_ v: CGFloat) -> CGFloat { CGFloat(max(2, Int((v * scale).rounded()) & ~1)) }
        let target = CGSize(width: even(oriented.width), height: even(oriented.height))
        let targetRect = CGRect(origin: .zero, size: target)
        let fps = max(1, Int(reader.info.nominalFrameRate.rounded()))
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("normalized-\(UUID().uuidString).mp4")
        var ok = false
        defer { if !ok { try? FileManager.default.removeItem(at: out) } }

        let writer = try VideoFrameWriter(outputURL: out, size: target, frameRate: fps)
        try writer.start()
        let s = CGAffineTransform(scaleX: target.width / oriented.width, y: target.height / oriented.height)
        while let frame = try reader.nextFrame() {
            try Task.checkCancellation()
            // makeFrameBuffer is the allocation-heavy Core Image / Metal half — drain it per frame
            // (mirrors the render loop's invariant); the async append stays outside the pool.
            let buffer = try autoreleasepool { () throws -> CVPixelBuffer in
                let scaled = frame.transformed(by: s).cropped(to: targetRect)
                return try writer.makeFrameBuffer(scaled, context: context)
            }
            try await writer.append(buffer)
        }
        try await writer.finish()
        ok = true
        return out
    }

    private static func isHDR(_ descriptions: [CMFormatDescription]) -> Bool {
        for desc in descriptions {
            guard let tf = CMFormatDescriptionGetExtension(
                desc, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
            else { continue }
            if tf == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) ||
               tf == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) {
                return true
            }
        }
        return false
    }
}

/// A video copied out of the photo library to a stable temp file the engine can read.
/// Used by the library's import action (`PhotosPicker` → `loadTransferable`).
struct PickedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { picked in
            SentTransferredFile(picked.url)
        } importing: { received in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("import-\(UUID().uuidString).mov")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedVideo(url: dest)
        }
    }
}
