import SwiftUI

/// First-launch explainer. The app only shines with the right footage (fixed camera, fast
/// subject), so the three cards teach exactly that — and "Try a demo clip" hands the user a
/// guaranteed-good synthetic clip so their first render succeeds in under a minute.
struct OnboardingView: View {
    var onTryDemo: () -> Void
    var onDone: () -> Void

    @State private var page = 0

    private struct Card {
        let icon: String
        let title: String
        let line: String
    }

    private let cards = [
        Card(icon: "camera.metering.center.weighted",
             title: "Lock your camera",
             line: "Prop your phone or use a tripod. The scene must hold still — only your subject should move."),
        Card(icon: "bird",
             title: "Catch fast motion",
             line: "Birds, cyclists, traffic. Fast subjects leave trails; slow drift like clouds is ignored."),
        Card(icon: "slider.horizontal.3",
             title: "Tune and share",
             line: "Adjust density and sensitivity on a live preview, then export a loop-ready video.")
    ]

    var body: some View {
        VStack(spacing: 0) {
            TrailMotif()
                .frame(height: 130)
                .padding(.top, 40)
                .padding(.horizontal, 28)

            TabView(selection: $page) {
                ForEach(Array(cards.enumerated()), id: \.offset) { index, card in
                    VStack(spacing: 14) {
                        Image(systemName: card.icon)
                            .font(.system(size: 44))
                            .foregroundStyle(Color.accentColor)
                        Text(card.title)
                            .font(.title2.bold())
                        Text(card.line)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 36)
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            VStack(spacing: 12) {
                if page < cards.count - 1 {
                    Button("Next") {
                        Theme.Haptics.tap()
                        withAnimation { page += 1 }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                } else {
                    Button {
                        Theme.Haptics.action()
                        onTryDemo()
                    } label: {
                        Label("Try a demo clip", systemImage: "sparkles")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                Button(page < cards.count - 1 ? "Skip" : "Get started") {
                    onDone()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .background(Theme.canvas.ignoresSafeArea())
    }
}

#Preview {
    OnboardingView(onTryDemo: {}, onDone: {})
        .preferredColorScheme(.dark)
}
