import SwiftUI
import AVKit
import Photos

/// Final screen: play the generated trail video, save it to Photos, or share it (spec §7.6).
struct ResultView: View {
    let resultURL: URL

    @Environment(MonetizationStore.self) private var monetization
    @State private var saveState: SaveState = .idle
    @State private var showPaywall = false
    private let player: AVPlayer

    init(resultURL: URL) {
        self.resultURL = resultURL
        self.player = AVPlayer(url: resultURL)
    }

    enum SaveState: Equatable {
        case idle, saving, saved
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 20) {
            VideoPlayer(player: player)
                .frame(maxWidth: .infinity)
                .frame(height: 320)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .onAppear {
                    player.actionAtItemEnd = .none
                    player.play()
                }

            HStack(spacing: 12) {
                Button {
                    save()
                } label: {
                    Label(saveLabel, systemImage: saveSymbol)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(saveState == .saving || saveState == .saved)

                ShareLink(item: resultURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            if case let .failed(message) = saveState {
                Text(message).font(.footnote).foregroundStyle(.red)
            }

            if monetization.watermarkEnabled {
                Button {
                    showPaywall = true
                } label: {
                    Label("This export has a watermark. Upgrade to remove.", systemImage: "crown")
                        .font(.footnote)
                }
                .padding(.top, 4)
            }

            Spacer()
        }
        .padding()
        .navigationTitle("Result")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .onDisappear { player.pause() }
    }

    private var saveLabel: String {
        switch saveState {
        case .idle, .failed: return "Save to Photos"
        case .saving: return "Saving…"
        case .saved: return "Saved"
        }
    }

    private var saveSymbol: String {
        saveState == .saved ? "checkmark.circle.fill" : "square.and.arrow.down"
    }

    private func save() {
        saveState = .saving
        PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: resultURL, options: nil)
        } completionHandler: { success, error in
            Task { @MainActor in
                saveState = success ? .saved : .failed(error?.localizedDescription ?? "Couldn't save to Photos.")
            }
        }
    }
}
