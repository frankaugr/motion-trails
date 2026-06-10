import Foundation

/// A saved capture and everything needed to re-render and re-export it (spec §10.5, §14):
/// the source video, the render settings, generated exports, a thumbnail, and metadata.
/// Persisted as `manifest.json` inside a per-project directory (see `ProjectStore`).
struct Project: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var createdAt: Date
    /// Optional user-given name (library rename). `nil` falls back to the capture date.
    /// Optional so manifests written before the field existed keep decoding.
    var name: String?
    /// Source clip filename within the project directory (e.g. "source.mov").
    var sourceFilename: String
    /// Poster thumbnail filename, if one was generated.
    var thumbnailFilename: String?
    /// Settings last used — also what a re-render starts from.
    var settings: RenderSettings
    /// Export filenames within the project's `exports/` subdirectory (newest last).
    var exportFilenames: [String]
    /// Source duration in seconds.
    var sourceDuration: Double

    init(id: UUID = UUID(),
         createdAt: Date = Date(),
         name: String? = nil,
         sourceFilename: String = "source.mov",
         thumbnailFilename: String? = nil,
         settings: RenderSettings = RenderSettings(),
         exportFilenames: [String] = [],
         sourceDuration: Double = 0) {
        self.id = id
        self.createdAt = createdAt
        self.name = name
        self.sourceFilename = sourceFilename
        self.thumbnailFilename = thumbnailFilename
        self.settings = settings
        self.exportFilenames = exportFilenames
        self.sourceDuration = sourceDuration
    }

    var hasExport: Bool { !exportFilenames.isEmpty }

    /// Library/editor title: the user's name for the project, falling back to the capture date.
    var displayName: String {
        if let name, !name.isEmpty { return name }
        return createdAt.formatted(.dateTime.month().day().hour().minute())
    }
}
