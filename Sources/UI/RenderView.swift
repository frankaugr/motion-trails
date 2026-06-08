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

    private let player: AVPlayer

    init(project: Project, sourceURL: URL) {
        self.project = project
        self.sourceURL = sourceURL
        _settings = State(initialValue: project.settings)
        self.player = AVPlayer(url: sourceURL)
    }

    private var speedSelection: Binding<Int> {
        Binding(get: { max(1, Int(settings.outputSpeed.rounded())) },
                set: { settings.outputSpeed = Double($0) })
    }

    var body: some View {
        Form {
            Section("Source") {
                VideoPlayer(player: player)
                    .frame(height: 200)
                    .listRowInsets(EdgeInsets())
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
                Picker("Speed", selection: speedSelection) {
                    ForEach(1...4, id: \.self) { Text("\($0)×").tag($0) }
                }
                .pickerStyle(.segmented)
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
        .onDisappear { renderTask?.cancel() }
        .navigationDestination(item: $result) { ref in
            ResultView(resultURL: ref.url)
        }
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .sheet(isPresented: $showMaskEditor) {
            MaskEditorView(sourceURL: sourceURL, regions: $settings.ignoreRegions)
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
