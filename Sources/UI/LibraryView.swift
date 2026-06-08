import SwiftUI
import PhotosUI
import UIKit

/// Home screen: a grid of saved projects with import, open-to-edit, and delete (spec §12.4).
struct LibraryView: View {
    @Environment(ProjectStore.self) private var store

    @State private var selection: PhotosPickerItem?
    @State private var editProject: Project?
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var showCapture = false

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]

    var body: some View {
        Group {
            if store.projects.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .navigationTitle("Motion Trails")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showCapture = true } label: { Image(systemName: "video.badge.plus") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                PhotosPicker(selection: $selection, matching: .videos, photoLibrary: .shared()) {
                    Image(systemName: "photo.badge.plus")
                }
                .disabled(isImporting)
            }
        }
        .fullScreenCover(isPresented: $showCapture) {
            CaptureView { project in
                showCapture = false
                // Let the cover finish dismissing before pushing the edit screen.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { editProject = project }
            }
        }
        .overlay {
            if isImporting {
                ProgressView("Importing…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .onChange(of: selection) { _, newValue in
            guard let newValue else { return }
            Task { await importVideo(newValue) }
        }
        .navigationDestination(item: $editProject) { project in
            RenderView(project: project, sourceURL: store.sourceURL(for: project))
        }
        .safeAreaInset(edge: .bottom) {
            if !store.projects.isEmpty {
                Text(storageFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
            }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(store.projects) { project in
                    Button { editProject = project } label: {
                        ProjectCard(project: project,
                                    thumbnailURL: store.thumbnailURL(for: project))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) { store.delete(project) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
            Text("No projects yet")
                .font(.title2.bold())
            Text("Record or import a fixed-camera clip to turn moving subjects into trails.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button { showCapture = true } label: {
                Label("Record a clip", systemImage: "video.fill")
                    .font(.headline)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            PhotosPicker(selection: $selection, matching: .videos, photoLibrary: .shared()) {
                Label("Import a clip", systemImage: "photo.on.rectangle.angled")
            }
            .buttonStyle(.bordered)
            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
        .padding(32)
    }

    private var storageFooter: String {
        let mb = Double(store.totalStorageBytes) / 1_000_000
        let count = store.projects.count
        return String(format: "%d project%@ · %.0f MB", count, count == 1 ? "" : "s", mb)
    }

    private func importVideo(_ item: PhotosPickerItem) async {
        isImporting = true
        errorMessage = nil
        defer { isImporting = false }
        do {
            guard let picked = try await item.loadTransferable(type: PickedVideo.self) else {
                errorMessage = "Couldn't load that video. Try another clip."
                return
            }
            let project = try await store.createProject(fromSourceURL: picked.url)
            try? FileManager.default.removeItem(at: picked.url)
            editProject = project
        } catch {
            importLog.error("import failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }
}

/// One project thumbnail tile in the library grid.
private struct ProjectCard: View {
    let project: Project
    let thumbnailURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                thumbnail
                    .aspectRatio(1, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                if project.hasExport {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.white, .green)
                        .padding(6)
                }

                Text(durationText)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(project.createdAt, format: .dateTime.month().day().hour().minute())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var thumbnail: some View {
        Group {
            if let thumbnailURL, let image = UIImage(contentsOfFile: thumbnailURL.path) {
                Image(uiImage: image).resizable()
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "film").font(.title).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var durationText: String {
        let total = Int(project.sourceDuration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
