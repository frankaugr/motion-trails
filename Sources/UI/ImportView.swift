import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import OSLog

let importLog = Logger(subsystem: "com.frank.motiontrails", category: "import")

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
