import SwiftUI

/// Capture screen (spec §12.1): live camera, record button with duration vs. the gated max,
/// pre-record stability check, and a low-light warning. On finish it creates a project and
/// hands it back via `onCaptured`.
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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if capture.permissionDenied {
                permissionDenied
            } else {
                CameraPreview(session: capture.session).ignoresSafeArea()
                overlay
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
    }

    private var overlay: some View {
        VStack {
            HStack(alignment: .top) {
                statusChip(icon: stability.stability.systemImage, text: stability.stability.label)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .padding(10)
                        .background(.black.opacity(0.5), in: Circle())
                        .foregroundStyle(.white)
                }
            }
            if let warning = capture.lightingWarning {
                statusChip(icon: "exclamationmark.triangle.fill", text: warning)
            }

            Spacer()

            VStack(spacing: 14) {
                Text(timeLabel)
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(.black.opacity(0.45), in: Capsule())

                recordButton

                Text(monetization.isPremium
                     ? "Up to \(Int(monetization.premiumRecordingLimit))s"
                     : "Free: up to \(Int(monetization.freeRecordingLimit))s · Upgrade for \(Int(monetization.premiumRecordingLimit))s")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.bottom, 28)

            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.white)
                    .padding(8).background(.red.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding()
    }

    private var recordButton: some View {
        Button {
            if capture.isRecording { capture.stop() } else { startRecording() }
        } label: {
            ZStack {
                Circle().stroke(.white, lineWidth: 4).frame(width: 76, height: 76)
                RoundedRectangle(cornerRadius: capture.isRecording ? 6 : 32)
                    .fill(.red)
                    .frame(width: capture.isRecording ? 34 : 62,
                           height: capture.isRecording ? 34 : 62)
                    .animation(.easeInOut(duration: 0.2), value: capture.isRecording)
            }
        }
        .disabled(!capture.isReady || isSaving)
    }

    private var permissionDenied: some View {
        VStack(spacing: 14) {
            Image(systemName: "video.slash").font(.system(size: 44)).foregroundStyle(.white)
            Text("Camera access is off").font(.title3.bold()).foregroundStyle(.white)
            Text("Enable camera access in Settings to record clips.")
                .font(.subheadline).foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
            Button("Close") { dismiss() }.buttonStyle(.borderedProminent)
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
        elapsed = 0
        errorMessage = nil
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            elapsed = min(elapsed + 0.1, monetization.maxRecordingDuration)
        }
        Task {
            do {
                let url = try await capture.record()
                ticker?.invalidate()
                isSaving = true
                let project = try await store.createProject(fromSourceURL: url)
                try? FileManager.default.removeItem(at: url)
                await MainActor.run {
                    isSaving = false
                    onCaptured(project)
                }
            } catch {
                await MainActor.run {
                    ticker?.invalidate()
                    isSaving = false
                    errorMessage = "Recording failed. Please try again."
                }
            }
        }
    }
}
