import SwiftUI
import AVKit

/// Edit screen: preview the source, tune the trail + output controls, render, and save the
/// export back into the project (spec §12.3, §6.2, §7.5, §7.6).
struct RenderView: View {
    let project: Project
    let sourceURL: URL

    @Environment(ProjectStore.self) private var store
    @Environment(MonetizationStore.self) private var monetization

    @State private var settings: RenderSettings
    @State private var isRendering = false
    @State private var progress: Double = 0
    @State private var result: VideoRef?
    @State private var errorMessage: String?
    @State private var renderTask: Task<Void, Never>?
    @State private var showPaywall = false
    @State private var showMaskEditor = false
    @State private var preview = TrailPreviewRenderer()
    @State private var prepareTask: Task<Void, Never>?

    init(project: Project, sourceURL: URL) {
        self.project = project
        self.sourceURL = sourceURL
        _settings = State(initialValue: project.settings)
    }

    /// Settings that change the per-frame mask and therefore need the preview re-prepared.
    private var maskKey: [Double] {
        [settings.sensitivity, settings.minMotionSize,
         settings.stabilizationEnabled ? 1 : 0,
         settings.backgroundMode == .slowUpdate ? 1 : 0]
    }

    var body: some View {
        Form {
            Section {
                trailPreview
                    .listRowInsets(EdgeInsets())
            } footer: {
                Text("Live preview of the final trail composition.")
            }

            Section("Trail frequency") {
                VStack(alignment: .leading, spacing: 6) {
                    Slider(value: $settings.trailFrequency, in: 0...1)
                    HStack {
                        Text("Sparse")
                        Spacer()
                        Text("Dense")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    Text("How often a silhouette is snapshotted into the trail. Drag to see the density change above.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Trail settings") {
                labeledSlider("Sensitivity", value: $settings.sensitivity,
                              caption: "Higher detects subtler motion.")
                labeledSlider("Minimum motion size", value: $settings.minMotionSize,
                              caption: "Higher ignores small speckles.")
                Toggle("Stabilization", isOn: $settings.stabilizationEnabled)
            }

            Section("Background") {
                Picker("Mode", selection: $settings.backgroundMode) {
                    ForEach(RenderSettings.BackgroundMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
            }

            Section("Output") {
                Picker("Aspect", selection: $settings.cropAspect) {
                    ForEach(RenderSettings.CropAspect.allCases) { aspect in
                        Text(aspect.label).tag(aspect)
                    }
                }
            }

            Section {
                if monetization.premiumEffectsUnlocked {
                    Picker("Trail mode", selection: $settings.trailMode) {
                        ForEach(RenderSettings.TrailMode.allCases) { Text($0.label).tag($0) }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Fade")
                        Slider(value: $settings.fadeAmount, in: 0...1)
                        Text("Older trails fade toward the background.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("Color", selection: $settings.colorStyle) {
                        ForEach(RenderSettings.ColorStyle.allCases) { Text($0.label).tag($0) }
                    }
                    Button {
                        showMaskEditor = true
                    } label: {
                        HStack {
                            Label("Ignore regions", systemImage: "rectangle.dashed")
                            Spacer()
                            Text(settings.ignoreRegions.isEmpty ? "None" : "\(settings.ignoreRegions.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Button {
                        showPaywall = true
                    } label: {
                        Label("Unlock fade, blend modes, color trails & ignore masks", systemImage: "crown")
                    }
                }
            } header: {
                Text("Premium effects")
            }

            Section {
                if isRendering {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: progress)
                        Text("Rendering… \(Int(progress * 100))%")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Cancel", role: .cancel) { renderTask?.cancel() }
                    }
                } else {
                    Button {
                        startRender()
                    } label: {
                        Label("Generate trail video", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }

                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red)
                }
            } footer: {
                if monetization.watermarkEnabled {
                    Button {
                        showPaywall = true
                    } label: {
                        Label("Free exports include a watermark. Upgrade to remove.", systemImage: "crown")
                            .font(.footnote)
                    }
                    .padding(.top, 4)
                }
            }
        }
        .navigationTitle("Edit")
        .navigationBarTitleDisplayMode(.inline)
        .task { await preview.prepare(sourceURL: sourceURL, settings: settings) }
        .onChange(of: settings.trailFrequency) { preview.recompose(settings: settings) }
        .onChange(of: settings.trailMode) { preview.recompose(settings: settings) }
        .onChange(of: maskKey) { schedulePrepare() }
        .onChange(of: showMaskEditor) { _, presented in
            // Re-prepare after editing ignore regions so the preview reflects them.
            if !presented { schedulePrepare() }
        }
        .onDisappear { renderTask?.cancel(); prepareTask?.cancel() }
        .navigationDestination(item: $result) { ref in
            ResultView(resultURL: ref.url)
        }
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .sheet(isPresented: $showMaskEditor) {
            MaskEditorView(sourceURL: sourceURL, regions: $settings.ignoreRegions)
        }
    }

    @ViewBuilder
    private var trailPreview: some View {
        ZStack {
            Color.black
            if let image = preview.previewImage {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .scaledToFit()
            }
            if preview.isPreparing || (preview.previewImage == nil && !preview.isReady) {
                ProgressView("Preparing preview…").tint(.white)
            }
        }
        .frame(height: 260)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func schedulePrepare() {
        prepareTask?.cancel()
        let url = sourceURL
        let settings = settings
        prepareTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            await preview.prepare(sourceURL: url, settings: settings)
        }
    }

    @ViewBuilder
    private func labeledSlider(_ title: String, value: Binding<Double>, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Slider(value: value, in: 0...1)
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func startRender() {
        isRendering = true
        progress = 0
        errorMessage = nil

        let engine = TrailRenderEngine()
        let settings = settings
        let url = sourceURL
        let project = project
        let store = store
        let watermark = monetization.watermarkEnabled
        let maxDimension = monetization.maxOutputDimension

        renderTask = Task {
            do {
                let outputURL = try await engine.render(sourceURL: url, settings: settings,
                                                        watermark: watermark,
                                                        maxOutputDimension: maxDimension) { fraction in
                    Task { @MainActor in progress = fraction }
                }
                await MainActor.run {
                    var updated = project
                    updated.settings = settings
                    try? store.update(updated)
                    let saved = (try? store.addExport(outputURL, to: updated)) ?? updated
                    let playable = store.latestExportURL(for: saved) ?? outputURL
                    result = VideoRef(url: playable)
                    isRendering = false
                }
            } catch is CancellationError {
                await MainActor.run { isRendering = false }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isRendering = false
                }
            }
        }
    }
}
