import SwiftUI
import AVKit
import Photos

/// Canvas-first edit screen (spec §12.3, §6.2, §7.5, §7.6): the live preview stays pinned while
/// one control group at a time is tuned beneath it, the primary action is always one tap away,
/// and the render's progress + result play back **in the same canvas** — no separate result
/// screen to push and pop around.
struct RenderView: View {
    let project: Project
    let sourceURL: URL

    @Environment(ProjectStore.self) private var store
    @Environment(MonetizationStore.self) private var monetization

    @State private var settings: RenderSettings
    @State private var phase: EditorPhase = .edit
    @State private var activeGroup: ControlGroup = .trails
    @State private var progress: Double = 0
    @State private var renderStage: TrailRenderEngine.RenderStage = .analyzing
    @State private var errorMessage: String?
    @State private var comparing = false
    @State private var saveState: SaveState = .idle

    @State private var preview = TrailPreviewRenderer()
    @State private var renderTask: Task<Void, Never>?
    @State private var prepareTask: Task<Void, Never>?
    @State private var persistTask: Task<Void, Never>?

    @State private var showPaywall = false
    @State private var showMaskEditor = false

    enum EditorPhase: Equatable {
        case edit
        case rendering
        case result(URL)
    }

    enum ControlGroup: String, CaseIterable, Identifiable {
        case trails, motion, scene, crop, effects
        var id: String { rawValue }

        var label: String {
            switch self {
            case .trails: return "Trails"
            case .motion: return "Motion"
            case .scene: return "Scene"
            case .crop: return "Crop"
            case .effects: return "Effects"
            }
        }
    }

    enum SaveState: Equatable {
        case idle, saving, saved
        case failed(String)
    }

    init(project: Project, sourceURL: URL) {
        self.project = project
        self.sourceURL = sourceURL
        _settings = State(initialValue: project.settings)
    }

    var body: some View {
        VStack(spacing: 0) {
            canvas
                .padding(.horizontal, 12)
                .padding(.top, 6)

            if case .result = phase {
                Spacer(minLength: 12)
            } else {
                chipRow
                controlPanel
            }

            bottomBar
        }
        .background(Theme.canvas.ignoresSafeArea())
        .navigationTitle(project.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task {
            await preview.prepare(sourceURL: sourceURL, settings: settings,
                                  cacheDirectory: store.directory(for: project))
        }
        .onChange(of: settings) { old, new in
            schedulePersist()
            if maskKey(old) != maskKey(new) {
                schedulePrepare()
            } else {
                preview.recompose(settings: new)
            }
        }
        .onDisappear {
            renderTask?.cancel()
            prepareTask?.cancel()
            persistTask?.cancel()
            persistSettings()
        }
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .sheet(isPresented: $showMaskEditor) {
            MaskEditorView(sourceURL: sourceURL, regions: $settings.ignoreRegions)
        }
    }

    // MARK: - Canvas

    @ViewBuilder
    private var canvas: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.surface)

                switch phase {
                case .result(let url):
                    LoopingPlayerView(url: url)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))

                case .edit, .rendering:
                    if let image = comparing ? preview.sourceImage : preview.previewImage {
                        Image(decorative: image, scale: 1, orientation: .up)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay { cropOverlay(in: geo.size, imageAspect: CGFloat(image.width) / CGFloat(image.height)) }
                            .padding(8)
                            .onLongPressGesture(minimumDuration: .infinity) {
                            } onPressingChanged: { pressing in
                                guard phase == .edit, preview.sourceImage != nil else { return }
                                comparing = pressing
                            }
                    }
                    if preview.isPreparing || (preview.previewImage == nil && !preview.isReady) {
                        ProgressView("Preparing preview…")
                            .tint(.white)
                            .foregroundStyle(.secondary)
                    }
                    if comparing {
                        canvasBadge("Source clip")
                    } else if phase == .edit, preview.previewImage != nil {
                        canvasBadge("Final frame · hold to compare")
                    }
                    if phase == .rendering {
                        renderingOverlay
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func canvasBadge(_ text: String) -> some View {
        VStack {
            HStack {
                Spacer()
                Text(text)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.black.opacity(0.55), in: Capsule())
            }
            Spacer()
        }
        .padding(14)
        .allowsHitTesting(false)
    }

    /// Dims the parts of the preview that the selected aspect will crop away, so the crop chips
    /// give immediate visual feedback.
    @ViewBuilder
    private func cropOverlay(in containerSize: CGSize, imageAspect: CGFloat) -> some View {
        if let ratio = settings.cropAspect.ratio, phase == .edit, !comparing {
            GeometryReader { imageGeo in
                let size = imageGeo.size
                let cropSize: CGSize = ratio > size.width / size.height
                    ? CGSize(width: size.width, height: size.width / ratio)
                    : CGSize(width: size.height * ratio, height: size.height)
                let inset = CGSize(width: (size.width - cropSize.width) / 2,
                                   height: (size.height - cropSize.height) / 2)
                ZStack {
                    Color.black.opacity(0.6)
                        .mask {
                            Rectangle()
                                .overlay(alignment: .center) {
                                    Rectangle()
                                        .frame(width: cropSize.width, height: cropSize.height)
                                        .blendMode(.destinationOut)
                                }
                                .compositingGroup()
                        }
                    Rectangle()
                        .strokeBorder(.white.opacity(0.7), lineWidth: 1)
                        .frame(width: cropSize.width, height: cropSize.height)
                        .position(x: inset.width + cropSize.width / 2,
                                  y: inset.height + cropSize.height / 2)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private var renderingOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.panelRadius).fill(.black.opacity(0.72))
            VStack(spacing: 14) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(Color.accentColor)
                    .frame(width: 180)
                Text(renderStage == .analyzing ? "Analyzing scene…" : "Rendering trails… \(Int(progress * 100))%")
                    .font(.subheadline)
                    .foregroundStyle(.white)
            }
        }
    }

    // MARK: - Control groups

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ControlGroup.allCases) { group in
                    chip(for: group)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 10)
        .disabled(phase == .rendering)
    }

    private func chip(for group: ControlGroup) -> some View {
        let selected = activeGroup == group
        return Button {
            Theme.Haptics.tap()
            withAnimation(.spring(duration: 0.3)) { activeGroup = group }
        } label: {
            HStack(spacing: 5) {
                if group == .effects && !monetization.premiumEffectsUnlocked {
                    Image(systemName: "crown.fill").font(.caption2)
                }
                Text(group.label)
            }
            .font(.subheadline.weight(selected ? .semibold : .regular))
            .foregroundStyle(selected ? Theme.onAccent : .secondary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Theme.surfaceBright), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var controlPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch activeGroup {
                case .trails: trailsPanel
                case .motion: motionPanel
                case .scene: scenePanel
                case .crop: cropPanel
                case .effects: effectsPanel
                }
            }
            .padding(16)
        }
        .frame(height: 222)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.panelRadius))
        .padding(.horizontal, 12)
        .disabled(phase == .rendering)
    }

    private var trailsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelRow("Density", value: trailFrequencyValue)
            Slider(value: $settings.trailFrequency, in: 0...1)
                .accessibilityLabel("Trail density")
                .accessibilityValue(trailFrequencyValue)
            scaleLabels("Sparse", "Dense")
            caption("A silhouette is left every \(trailFrequencyValue) of the clip, whatever its length.")
        }
    }

    private var motionPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                panelRow("Subject contrast", value: settings.contrastMode.label)
                optionChips(RenderSettings.ContrastMode.allCases, selection: $settings.contrastMode) { $0.label }
                caption(settings.contrastMode.caption)
            }
            VStack(alignment: .leading, spacing: 8) {
                panelRow("Speed threshold", value: nil)
                Slider(value: $settings.motionHorizonSeconds, in: 0.1...0.6)
                    .accessibilityLabel("Motion speed threshold")
                scaleLabels("Only fast", "Include slower")
                caption("Lower keeps only the fastest motion (birds) and ignores slow drift like clouds.")
            }
        }
    }

    private var scenePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                panelRow("Trails sit over", value: nil)
                optionChips(RenderSettings.BackgroundMode.allCases, selection: $settings.backgroundMode) { $0.label }
                caption(settings.backgroundMode.caption)
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $settings.stabilizationEnabled) {
                    Text("Reduce camera shake").font(.subheadline)
                }
                .tint(Color.accentColor)
                caption("For handheld clips only — on tripod footage leave this off.")
            }
        }
    }

    private var cropPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelRow("Export aspect", value: nil)
            optionChips(RenderSettings.CropAspect.allCases, selection: $settings.cropAspect) { $0.label }
            caption("Cropped after processing — the dimmed area won't be exported.")
        }
    }

    @ViewBuilder
    private var effectsPanel: some View {
        if monetization.premiumEffectsUnlocked {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    panelRow("Blend", value: nil)
                    optionChips(RenderSettings.TrailMode.allCases, selection: $settings.trailMode) { $0.label }
                }
                VStack(alignment: .leading, spacing: 8) {
                    panelRow("Fade", value: nil)
                    Slider(value: $settings.fadeAmount, in: 0...1)
                        .accessibilityLabel("Trail fade")
                    caption("Older trails fade toward the background.")
                }
                VStack(alignment: .leading, spacing: 8) {
                    panelRow("Color", value: nil)
                    optionChips(RenderSettings.ColorStyle.allCases, selection: $settings.colorStyle) { $0.label }
                }
                Button {
                    showMaskEditor = true
                } label: {
                    HStack {
                        Label("Ignore regions", systemImage: "rectangle.dashed")
                            .font(.subheadline)
                        Spacer()
                        Text(settings.ignoreRegions.isEmpty ? "None" : "\(settings.ignoreRegions.count)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8).padding(.horizontal, 12)
                    .background(Theme.surfaceBright, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Label("Premium effects", systemImage: "crown.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                caption("Fade, blend modes, color trails and ignore-region masks.")
                Button("Unlock Premium") { showPaywall = true }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    // MARK: - Panel building blocks

    private func panelRow(_ title: String, value: String?) -> some View {
        HStack {
            Text(title).font(.subheadline.weight(.medium))
            Spacer()
            if let value {
                Text(value).font(.subheadline).foregroundStyle(Color.accentColor)
            }
        }
    }

    private func scaleLabels(_ low: String, _ high: String) -> some View {
        HStack {
            Text(low)
            Spacer()
            Text(high)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private func optionChips<T: Hashable>(_ options: [T], selection: Binding<T>,
                                          label: @escaping (T) -> String) -> some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.self) { option in
                let selected = selection.wrappedValue == option
                Button {
                    Theme.Haptics.tap()
                    selection.wrappedValue = option
                } label: {
                    Text(label(option))
                        .font(.caption.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Theme.onAccent : .secondary)
                        .padding(.horizontal, 11).padding(.vertical, 7)
                        .background(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Theme.surfaceBright),
                                    in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 10) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            switch phase {
            case .edit:
                if monetization.watermarkEnabled {
                    UpsellChip(text: "Free exports include a watermark — remove") { showPaywall = true }
                }
                Button { startRender() } label: {
                    Label("Generate · \(clipLengthText) clip", systemImage: "sparkles")
                }
                .buttonStyle(PrimaryButtonStyle())

            case .rendering:
                Button("Cancel", role: .cancel) { renderTask?.cancel() }
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.surfaceBright, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))

            case .result(let url):
                if monetization.watermarkEnabled {
                    UpsellChip(text: "This export has a watermark — remove") { showPaywall = true }
                }
                HStack(spacing: 10) {
                    Button { saveToPhotos(url) } label: {
                        Label(saveLabel, systemImage: saveState == .saved ? "checkmark.circle.fill" : "square.and.arrow.down")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(saveState == .saving || saveState == .saved)

                    ShareLink(item: url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Theme.surfaceBright, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
                    }
                }
                Button("Keep tuning") {
                    Theme.Haptics.tap()
                    saveState = .idle
                    withAnimation(.spring(duration: 0.35)) { phase = .edit }
                }
                .font(.subheadline)
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private var clipLengthText: String {
        let seconds = max(1, Int(project.sourceDuration.rounded()))
        return "\(seconds) s"
    }

    private var trailFrequencyValue: String {
        let s = settings.snapshotIntervalSeconds
        return s < 1 ? String(format: "%.2f s", s) : String(format: "%.1f s", s)
    }

    private var saveLabel: String {
        switch saveState {
        case .idle, .failed: return "Save to Photos"
        case .saving: return "Saving…"
        case .saved: return "Saved"
        }
    }

    // MARK: - Preview preparation

    /// Settings that change the per-frame mask and therefore need the preview re-prepared:
    /// contrast mode, the motion horizon, and ignore regions (now baked into the proxy layers).
    /// Everything else (frequency, blend, fade, color, backdrop) is a cheap `recompose`.
    private func maskKey(_ s: RenderSettings) -> String {
        let regions = s.ignoreRegions.map {
            String(format: "%.3f,%.3f,%.3f,%.3f", $0.minX, $0.minY, $0.width, $0.height)
        }.joined(separator: ";")
        return "\(s.contrastMode.rawValue)|\(Int((s.motionHorizonSeconds * 100).rounded()))|\(regions)"
    }

    private func schedulePrepare() {
        prepareTask?.cancel()
        let url = sourceURL
        let settings = settings
        let cacheDir = store.directory(for: project)
        prepareTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            await preview.prepare(sourceURL: url, settings: settings, cacheDirectory: cacheDir)
        }
    }

    // MARK: - Settings persistence

    /// Settings persist as they change (debounced), not only when a render is started —
    /// leaving the editor no longer discards tuning.
    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            if Task.isCancelled { return }
            await MainActor.run { persistSettings() }
        }
    }

    private func persistSettings() {
        guard var current = store.projects.first(where: { $0.id == project.id }),
              current.settings != settings else { return }
        current.settings = settings
        try? store.update(current)
    }

    // MARK: - Render

    private func startRender() {
        Theme.Haptics.action()
        phase = .rendering
        progress = 0
        renderStage = .analyzing
        errorMessage = nil

        let engine = TrailRenderEngine()
        let settings = settings
        let url = sourceURL
        let projectID = project.id
        let store = store
        let watermark = monetization.watermarkEnabled
        let maxDimension = monetization.maxOutputDimension

        renderTask = Task {
            do {
                let outputURL = try await engine.render(sourceURL: url, settings: settings,
                                                        watermark: watermark,
                                                        maxOutputDimension: maxDimension) { fraction in
                    Task { @MainActor in progress = fraction }
                } stage: { stage in
                    Task { @MainActor in renderStage = stage }
                }
                await MainActor.run {
                    persistSettings()
                    var playable = outputURL
                    if let current = store.projects.first(where: { $0.id == projectID }),
                       let saved = try? store.addExport(outputURL, to: current),
                       let exportURL = store.latestExportURL(for: saved) {
                        playable = exportURL
                        // The render's temp file has been copied into the project — drop it.
                        try? FileManager.default.removeItem(at: outputURL)
                    }
                    saveState = .idle
                    withAnimation(.spring(duration: 0.35)) { phase = .result(playable) }
                    Theme.Haptics.success()
                }
            } catch is CancellationError {
                await MainActor.run { phase = .edit }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    phase = .edit
                    Theme.Haptics.failure()
                }
            }
        }
    }

    // MARK: - Save to Photos

    private func saveToPhotos(_ url: URL) {
        saveState = .saving
        PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
        } completionHandler: { success, error in
            Task { @MainActor in
                if success {
                    saveState = .saved
                    Theme.Haptics.success()
                } else {
                    saveState = .failed(error?.localizedDescription ?? "Couldn't save to Photos.")
                    errorMessage = error?.localizedDescription ?? "Couldn't save to Photos."
                    Theme.Haptics.failure()
                }
            }
        }
    }
}
