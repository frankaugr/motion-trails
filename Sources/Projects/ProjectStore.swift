import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Observation

enum ProjectStoreError: Error, LocalizedError {
    case thumbnailEncodeFailed
    var errorDescription: String? { "Couldn't write the project thumbnail." }
}

/// File-based project storage (spec §10.5, §14). Each project lives in its own directory under
/// the store root:
///
///     <root>/<uuid>/manifest.json     // Codable Project
///                   source.mov        // retained source clip
///                   thumbnail.jpg     // poster frame
///                   exports/*.mp4     // generated trail videos
///
/// Projects are retained indefinitely until explicitly deleted. The root defaults to
/// Application Support/Projects but is injectable for tests/harnesses.
@Observable
final class ProjectStore {
    private(set) var projects: [Project] = []
    let rootDirectory: URL

    init(rootDirectory: URL? = nil) {
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.rootDirectory = appSupport.appendingPathComponent("Projects", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.rootDirectory, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Path helpers

    func directory(for project: Project) -> URL {
        rootDirectory.appendingPathComponent(project.id.uuidString, isDirectory: true)
    }
    func sourceURL(for project: Project) -> URL {
        directory(for: project).appendingPathComponent(project.sourceFilename)
    }
    func thumbnailURL(for project: Project) -> URL? {
        project.thumbnailFilename.map { directory(for: project).appendingPathComponent($0) }
    }
    func exportsDirectory(for project: Project) -> URL {
        directory(for: project).appendingPathComponent("exports", isDirectory: true)
    }
    func exportURLs(for project: Project) -> [URL] {
        let dir = exportsDirectory(for: project)
        return project.exportFilenames.map { dir.appendingPathComponent($0) }
    }
    func latestExportURL(for project: Project) -> URL? { exportURLs(for: project).last }

    // MARK: - Load

    func load() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: rootDirectory,
                                                         includingPropertiesForKeys: [.isDirectoryKey]) else {
            projects = []
            return
        }
        var loaded: [Project] = []
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            let manifest = entry.appendingPathComponent("manifest.json")
            if let data = try? Data(contentsOf: manifest),
               let project = try? JSONDecoder().decode(Project.self, from: data) {
                loaded.append(project)
            }
        }
        projects = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Create

    /// Copies `sourceURL` into a new project directory, reads its duration, generates a
    /// thumbnail, writes the manifest, and inserts it into `projects`.
    @discardableResult
    func createProject(fromSourceURL sourceURL: URL,
                       settings: RenderSettings = RenderSettings()) async throws -> Project {
        let id = UUID()
        let dir = rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
        let sourceFilename = "source.\(ext)"
        let destSource = dir.appendingPathComponent(sourceFilename)
        try FileManager.default.copyItem(at: sourceURL, to: destSource)

        let asset = AVURLAsset(url: destSource)
        let duration = (try? await asset.load(.duration).seconds) ?? 0

        var project = Project(id: id, sourceFilename: sourceFilename,
                              settings: settings, sourceDuration: duration)

        if let cgImage = try? await Self.generateThumbnail(asset: asset, duration: duration) {
            let thumbURL = dir.appendingPathComponent("thumbnail.jpg")
            if (try? Self.writeJPEG(cgImage, to: thumbURL)) != nil {
                project.thumbnailFilename = "thumbnail.jpg"
            }
        }

        try writeManifest(project)
        await insert(project)
        return project
    }

    // MARK: - Update / export / delete

    /// Persists changed settings (or other fields) for an existing project.
    func update(_ project: Project) throws {
        try writeManifest(project)
        replace(project)
    }

    /// Copies a freshly rendered export into the project's `exports/` directory and records it.
    @discardableResult
    func addExport(_ outputURL: URL, to project: Project) throws -> Project {
        let exportsDir = exportsDirectory(for: project)
        try FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)
        let filename = "export-\(Int(Date().timeIntervalSince1970)).mp4"
        try FileManager.default.copyItem(at: outputURL, to: exportsDir.appendingPathComponent(filename))

        var updated = project
        updated.exportFilenames.append(filename)
        try writeManifest(updated)
        replace(updated)
        return updated
    }

    func delete(_ project: Project) {
        try? FileManager.default.removeItem(at: directory(for: project))
        projects.removeAll { $0.id == project.id }
    }

    /// Total bytes used by all stored projects (spec §14 storage indicator).
    var totalStorageBytes: Int64 {
        directorySize(rootDirectory)
    }

    // MARK: - Private

    private func writeManifest(_ project: Project) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(project)
        try data.write(to: directory(for: project).appendingPathComponent("manifest.json"))
    }

    @MainActor
    private func insert(_ project: Project) {
        projects.removeAll { $0.id == project.id }
        projects.insert(project, at: 0)
    }

    private func replace(_ project: Project) {
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
        } else {
            projects.insert(project, at: 0)
        }
    }

    private func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += Int64(size)
        }
        return total
    }

    private static func generateThumbnail(asset: AVURLAsset, duration: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.3, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.3, preferredTimescale: 600)
        // Mid-clip avoids black fade-in frames.
        let seconds = duration > 0 ? min(duration * 0.5, max(0, duration - 0.1)) : 0
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        return try await generator.image(at: time).image
    }

    private static func writeJPEG(_ cgImage: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw ProjectStoreError.thumbnailEncodeFailed }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ProjectStoreError.thumbnailEncodeFailed }
    }
}
