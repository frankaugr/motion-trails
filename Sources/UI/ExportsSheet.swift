import SwiftUI
import AVKit

/// Per-project export manager: every rendered MP4 stays accessible — play, share, or delete —
/// instead of being reachable only in the moments after a render.
struct ExportsSheet: View {
    let project: Project

    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var playURL: VideoRef?

    /// Live copy from the store, so deletions update the list immediately.
    private var current: Project {
        store.projects.first(where: { $0.id == project.id }) ?? project
    }

    var body: some View {
        NavigationStack {
            Group {
                if current.exportFilenames.isEmpty {
                    ContentUnavailableView("No exports yet",
                                           systemImage: "tray",
                                           description: Text("Generate a trail video from the editor to see it here."))
                } else {
                    exportList
                }
            }
            .background(Theme.canvas.ignoresSafeArea())
            .navigationTitle("Exports")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
            .sheet(item: $playURL) { ref in
                ExportPlayerSheet(url: ref.url)
            }
        }
    }

    private var exportList: some View {
        List {
            // Newest last in the manifest → show newest first.
            ForEach(current.exportFilenames.reversed(), id: \.self) { filename in
                let url = store.exportsDirectory(for: current).appendingPathComponent(filename)
                HStack(spacing: 12) {
                    Button {
                        playURL = VideoRef(url: url)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "play.circle.fill")
                                .font(.title2)
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(dateText(filename))
                                    .font(.subheadline.weight(.medium))
                                Text(sizeText(url))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                }
                .listRowBackground(Theme.surface)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        store.deleteExport(filename, from: current)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func dateText(_ filename: String) -> String {
        guard let date = ProjectStore.exportDate(filename: filename) else { return filename }
        return date.formatted(.dateTime.month().day().hour().minute())
    }

    private func sizeText(_ url: URL) -> String {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Full-screen-ish looping playback of one export, with share.
struct ExportPlayerSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LoopingPlayerView(url: url)
                .background(Color.black)
                .navigationTitle("Export")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                    }
                }
        }
    }
}
