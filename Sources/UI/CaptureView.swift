import SwiftUI

/// Capture screen (spec §12.1): live camera, record button with a countdown ring against the
/// gated max duration, pre-record stability check, framing grid + level, and a low-light
/// warning. On finish it creates a project and hands it back via `onCaptured`.
struct CaptureView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(MonetizationStore.self) private var monetization
    @Environment(\.dismiss) private var dismiss

    var onCaptured: (Project) -> Void

    @State private var capture = CaptureService()
    @State private var stability = StabilityMonitor()
    @State private var elapsed: Double = 0
    @State private var ticker: Timer?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showGrid = true
    @State private var showPaywall = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if capture.permissionDenied {
                permissionDenied
            } else {
                CameraPreview(session: capture.session).ignoresSafeArea()
                if showGrid { gridOverlay }
                overlay
            }

            if isSaving {
                savingOverlay
            }
        }
        .task {
            capture.maxRecordingDuration = monetization.maxRecordingDuration
            await capture.configure()
            capture.startRunning()
            capture.lockSettings()
            stability.start()
        }
        .onDisappear {
            ticker?.invalidate()
            capture.stopRunning()
            stability.stop()
        }
        .sheet(isPresented: $showPaywall) { PaywallView() }
    }

    // MARK: - Overlays

    private var overlay: some View {
        VStack {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    statusChip(icon: stability.stability.systemImage, text: stability.stability.label)
                    if let warning = capture.lightingWarning {
                        statusChip(icon: "exclamationmark.triangle.fill", text: warning)
                    }
                }
                Spacer()
                VStack(spacing: 10) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .padding(10)
                            .background(.black.opacity(0.5), in: Circle())
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel("Close")
                    Button { showGrid.toggle() } label: {
                        Image(systemName: showGrid ? "grid" : "grid.circle")
                            .font(.headline)
                            .padding(10)
                            .background(.black.opacity(0.5), in: Circle())
                            .foregroundStyle(showGrid ? Color.accentColor : .white)
                    }
                    .accessibilityLabel("Toggle framing grid")
                }
            }

            Spacer()

            VStack(spacing: 14) {
                if showGrid { levelIndicator }

                Text(timeLabel)
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(.black.opacity(0.45), in: Capsule())

                recordButton

                if monetization.isPremium {
                    Text("Up to \(Int(monetization.premiumRecordingLimit))s")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                } else {
                    UpsellChip(text: "Free: \(Int(monetization.freeRecordingLimit))s · unlock \(Int(monetization.premiumRecordingLimit))s") {
                        showPaywall = true
                    }
                }
            }
            .padding(.bottom, 28)

            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.white)
                    .padding(8).background(.red.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding()
    }

    /// Rule-of-thirds framing lines — composition aid for a camera that must stay fixed.
    private var gridOverlay: some View {
        GeometryReader { geo in
            Path { path in
                for fraction in [1.0 / 3.0, 2.0 / 3.0] {
                    path.move(to: CGPoint(x: geo.size.width * fraction, y: 0))
                    path.addLine(to: CGPoint(x: geo.size.width * fraction, y: geo.size.height))
                    path.move(to: CGPoint(x: 0, y: geo.size.height * fraction))
                    path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height * fraction))
                }
            }
            .stroke(.white.opacity(0.25), lineWidth: 0.7)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// Horizon level: a short line that rotates with the device's sideways tilt and snaps
    /// to the accent color when the framing is level.
    private var levelIndicator: some View {
        let level = abs(stability.tiltDegrees) < 1.5
        return Rectangle()
            .fill(level ? Color.accentColor : .white.opacity(0.8))
            .frame(width: level ? 72 : 56, height: 2)
            .rotationEffect(.degrees(level ? 0 : -stability.tiltDegrees))
            .animation(.easeOut(duration: 0.15), value: level)
            .accessibilityLabel(level ? "Level" : "Tilted \(Int(stability.tiltDegrees)) degrees")
    }

    private var recordButton: some View {
        Button {
            if capture.isRecording { capture.stop() } else { startRecording() }
        } label: {
            ZStack {
                Circle().stroke(.white.opacity(0.5), lineWidth: 4).frame(width: 76, height: 76)
                // Countdown ring: fills as the recording approaches the tier's cap.
                Circle()
                    .trim(from: 0, to: capture.isRecording ? min(1, elapsed / monetization.maxRecordingDuration) : 0)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 76, height: 76)
                RoundedRectangle(cornerRadius: capture.isRecording ? 6 : 32)
                    .fill(.red)
                    .frame(width: capture.isRecording ? 34 : 62,
                           height: capture.isRecording ? 34 : 62)
                    .animation(.easeInOut(duration: 0.2), value: capture.isRecording)
            }
        }
        .disabled(!capture.isReady || isSaving)
        .accessibilityLabel(capture.isRecording ? "Stop recording" : "Start recording")
    }

    private var savingOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            ProgressView("Saving clip…")
                .tint(.white)
                .foregroundStyle(.white)
                .padding(20)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
        }
    }

    private var permissionDenied: some View {
        VStack(spacing: 14) {
            Image(systemName: "video.slash").font(.system(size: 44)).foregroundStyle(.white)
            Text("Camera access is off").font(.title3.bold()).foregroundStyle(.white)
            Text("Enable camera access in Settings to record clips.")
                .font(.subheadline).foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
            Button("Close") { dismiss() }.buttonStyle(PrimaryButtonStyle())
        }
        .padding(32)
    }

    private func statusChip(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.black.opacity(0.5), in: Capsule())
            .foregroundStyle(.white)
    }

    private var timeLabel: String {
        String(format: "%.1f / %ds", elapsed, Int(monetization.maxRecordingDuration))
    }

    private func startRecording() {
        Theme.Haptics.action()
        elapsed = 0
        errorMessage = nil
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            elapsed = min(elapsed + 0.1, monetization.maxRecordingDuration)
        }
        Task {
            do {
                let url = try await capture.record()
                Theme.Haptics.action()
                ticker?.invalidate()
                isSaving = true
                let project = try await store.createProject(fromSourceURL: url)
                try? FileManager.default.removeItem(at: url)
                await MainActor.run {
                    isSaving = false
                    Theme.Haptics.success()
                    onCaptured(project)
                }
            } catch {
                await MainActor.run {
                    ticker?.invalidate()
                    isSaving = false
                    errorMessage = "Recording failed. Please try again."
                    Theme.Haptics.failure()
                }
            }
        }
    }
}
