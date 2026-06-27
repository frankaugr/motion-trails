import SwiftUI
import PhotosUI
import UIKit
import ImageIO

/// Home screen (spec §12.4): a grid of saved projects with capture, import, rename, export
/// management and delete. First launch shows onboarding and can seed a generated demo project.
struct LibraryView: View {
    @Environment(ProjectStore.self) private var store

    @AppStorage("com.frank.motiontrails.hasOnboarded") private var hasOnboarded = false

    @State private var selection: PhotosPickerItem?
    @State private var editProject: Project?
    @State private var pendingProject: Project?
    @State private var isImporting = false
    @State private var importStatus = "Importing…"
    @State private var errorMessage: String?
    @State private var showCapture = false
    @State private var renameTarget: Project?
    @State private var renameText = ""
    @State private var exportsTarget: Project?
    @State private var playExport: VideoRef?
    @State private var storageText: String?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]

    var body: some View {
        Group {
            if store.projects.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .background(Theme.canvas.ignoresSafeArea())
        .navigationTitle("Motion Trails")
        .toolbarBackground(Theme.canvas, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showCapture = true } label: { Image(systemName: "video.badge.plus") }
                    .accessibilityLabel("Record a clip")
            }
            ToolbarItem(placement: .topBarTrailing) {
                importControl {
                    Image(systemName: "photo.badge.plus")
                }
                .accessibilityLabel("Import a clip")
            }
        }
        .fullScreenCover(isPresented: $showCapture) {
            // The capture screen hands its project back; we push the editor only after the
            // cover has actually finished dismissing (no timing hacks).
            if let project = pendingProject {
                pendingProject = nil
                editProject = project
            }
        } content: {
            CaptureView { project in
                pendingProject = project
                showCapture = false
            }
        }
        .fullScreenCover(isPresented: onboardingBinding) {
            OnboardingView(
                onTryDemo: {
                    hasOnboarded = true
                    Task { await createDemoProject() }
                },
                onDone: { hasOnboarded = true }
            )
        }
        .overlay {
            if isImporting {
                ProgressView(importStatus)
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            }
        }
        .onChange(of: selection) { _, newValue in
            guard let newValue else { return }
            Task { await importVideo(newValue) }
        }
        .navigationDestination(item: $editProject) { project in
            RenderView(project: project, sourceURL: store.sourceURL(for: project))
        }
        .sheet(item: $exportsTarget) { project in
            ExportsSheet(project: project)
        }
        .sheet(item: $playExport) { ref in
            ExportPlayerSheet(url: ref.url)
        }
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Rename project", isPresented: renameBinding) {
            TextField("Project name", text: $renameText)
            Button("Save") {
                if let target = renameTarget { store.rename(target, to: renameText) }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .safeAreaInset(edge: .bottom) {
            if let storageText, !store.projects.isEmpty {
                Text(storageText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
            }
        }
        .task(id: store.projects) { await refreshStorage() }
    }

    // MARK: - Bindings

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var onboardingBinding: Binding<Bool> {
        Binding(get: { !hasOnboarded }, set: { hasOnboarded = !$0 })
    }

    // MARK: - Grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(store.projects) { project in
                    Button { editProject = project } label: {
                        ProjectCard(project: project,
                                    thumbnailURL: store.thumbnailURL(for: project))
                    }
                    .buttonStyle(.plain)
                    .contextMenu { contextMenu(for: project) }
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func contextMenu(for project: Project) -> some View {
        Button {
            renameText = project.name ?? ""
            renameTarget = project
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        if let latest = store.latestExportURL(for: project) {
            Button {
                playExport = VideoRef(url: latest)
            } label: {
                Label("Play latest export", systemImage: "play.rectangle")
            }
            Button {
                exportsTarget = project
            } label: {
                Label("Exports…", systemImage: "tray.full")
            }
        }
        Button(role: .destructive) { store.delete(project) } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 18) {
            TrailMotif()
                .frame(height: 110)
                .padding(.horizontal, 24)
            Text("Turn motion into trails")
                .font(.title2.bold())
            Text("Record a fixed-camera clip of something fast — birds, cyclists, traffic — and every pass paints a trail over a still scene.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button { showCapture = true } label: {
                Label("Record a clip", systemImage: "video.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            importControl {
                Label("Import a clip", systemImage: "photo.on.rectangle.angled")
                    .font(.subheadline.weight(.medium))
            }
            Button("Try a demo clip") {
                Task { await createDemoProject() }
            }
            .font(.subheadline)
            .foregroundStyle(Color.accentColor)
        }
        .padding(32)
    }

    // MARK: - Import / demo

    private func importControl<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        PhotosPicker(selection: $selection, matching: .videos, photoLibrary: .shared()) {
            label()
        }
        .disabled(isImporting)
    }

    private func importVideo(_ item: PhotosPickerItem) async {
        importStatus = "Importing…"
        isImporting = true
        errorMessage = nil
        defer { isImporting = false }
        do {
            guard let picked = try await item.loadTransferable(type: PickedVideo.self) else {
                errorMessage = "Couldn't load that video. Try another clip."
                return
            }
            importStatus = "Preparing clip…"
            // Validate (reject no-video-track / over-length) and downscale 4K/HDR before render.
            let source = try await ClipImporter.normalize(picked.url)
            let project = try await store.createProject(fromSourceURL: source)
            try? FileManager.default.removeItem(at: picked.url)
            if source != picked.url { try? FileManager.default.removeItem(at: source) }
            editProject = project
        } catch let error as ImportError {
            errorMessage = error.errorDescription
            Theme.Haptics.failure()
        } catch {
            importLog.error("import failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
            Theme.Haptics.failure()
        }
    }

    /// Synthesizes the demo clip and opens it as a project — the fastest path to a first
    /// successful render for someone with no suitable footage yet.
    private func createDemoProject() async {
        importStatus = "Creating demo…"
        isImporting = true
        errorMessage = nil
        defer { isImporting = false }
        do {
            // Prefer the bundled real-footage demo clip (Resources/DemoClip.mp4) — copied to a temp
            // file so the cleanup below never touches the read-only app bundle. Fall back to the
            // synthesized clip if it's somehow absent from the bundle.
            let clipURL: URL
            if let bundled = Bundle.main.url(forResource: "DemoClip", withExtension: "mp4") {
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("demo-\(UUID().uuidString).mp4")
                try FileManager.default.copyItem(at: bundled, to: tmp)
                clipURL = tmp
            } else {
                clipURL = try await SampleClipFactory().makeClip()
            }
            // Seed the demo with settings tuned for the footage (dark birds on a bright sky), so the
            // first render already looks like the showcase rather than the neutral default.
            var demoSettings = RenderSettings()
            demoSettings.contrastMode = .silhouette
            demoSettings.trailFrequency = 0.8
            var project = try await store.createProject(fromSourceURL: clipURL, settings: demoSettings)
            try? FileManager.default.removeItem(at: clipURL)
            project.name = "Demo · flying birds"
            try? store.update(project)
            editProject = project
        } catch {
            errorMessage = "Couldn't create the demo clip."
            Theme.Haptics.failure()
        }
    }

    private func refreshStorage() async {
        guard !store.projects.isEmpty else {
            storageText = nil
            return
        }
        let bytes = await store.computeTotalStorageBytes()
        let mb = Double(bytes) / 1_000_000
        let count = store.projects.count
        storageText = String(format: "%d project%@ · %.0f MB", count, count == 1 ? "" : "s", mb)
    }
}

/// One project tile in the library grid.
private struct ProjectCard: View {
    let project: Project
    let thumbnailURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                ProjectThumbnail(url: thumbnailURL)
                    .aspectRatio(1, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))

                HStack {
                    Text(durationText)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white)
                    Spacer()
                    if project.hasExport {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.onAccent, Color.accentColor)
                    }
                }
                .padding(8)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(project.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(project.createdAt, format: .dateTime.month().day().year())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var durationText: String {
        let total = Int(project.sourceDuration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Async, downsampled thumbnail — full-resolution JPEG decodes stay off the main thread.
private struct ProjectThumbnail: View {
    let url: URL?
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable()
            } else {
                ZStack {
                    Rectangle().fill(Theme.surface)
                    Image(systemName: "film").font(.title).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: url) { image = await Self.load(url) }
    }

    private static func load(_ url: URL?) async -> UIImage? {
        guard let url else { return nil }
        return await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 480
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                .map { UIImage(cgImage: $0) }
        }.value
    }
}
