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

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, name, sourceFilename, thumbnailFilename, settings, exportFilenames, sourceDuration
    }

    /// Forgiving decode (mirrors `RenderSettings.init(from:)`): every field falls back to a default
    /// rather than throwing, so adding a field in a future schema — or an old manifest missing one —
    /// never drops the project from the library. Encoding stays synthesized.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        name = try? c.decode(String.self, forKey: .name)
        sourceFilename = (try? c.decode(String.self, forKey: .sourceFilename)) ?? "source.mov"
        thumbnailFilename = try? c.decode(String.self, forKey: .thumbnailFilename)
        settings = (try? c.decode(RenderSettings.self, forKey: .settings)) ?? RenderSettings()
        exportFilenames = (try? c.decode([String].self, forKey: .exportFilenames)) ?? []
        sourceDuration = (try? c.decode(Double.self, forKey: .sourceDuration)) ?? 0
    }

    var hasExport: Bool { !exportFilenames.isEmpty }

    /// Library/editor title: the user's name for the project, falling back to the capture date.
    var displayName: String {
        if let name, !name.isEmpty { return name }
        return createdAt.formatted(.dateTime.month().day().hour().minute())
    }
}
