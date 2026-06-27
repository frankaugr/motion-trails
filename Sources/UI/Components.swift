import SwiftUI
import AVKit

/// Small shared UI pieces used across screens, so playback and branding stay consistent.

/// Seamlessly looping video playback — trail clips are short and read best on a loop.
/// (`AVPlayer` alone freezes on the last frame; `AVPlayerLooper` needs a queue player.)
struct LoopingPlayerView: View {
    let url: URL

    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?

    var body: some View {
        VideoPlayer(player: player)
            .onAppear {
                let item = AVPlayerItem(url: url)
                let queue = AVQueuePlayer()
                looper = AVPlayerLooper(player: queue, templateItem: item)
                queue.isMuted = true
                queue.play()
                player = queue
            }
            .onDisappear {
                player?.pause()
                looper = nil
                player = nil
            }
    }
}

/// Animated brand motif: a dot sweeping a sine path, leaving fading copies — the app's effect,
/// abstracted. Used by onboarding and the library's empty state.
struct TrailMotif: View {
    var dotColor: Color = .accentColor

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let period = 4.0
                let phase = (t.truncatingRemainder(dividingBy: period)) / period
                let ghostCount = 9
                for ghost in stride(from: ghostCount, through: 0, by: -1) {
                    let gPhase = phase - Double(ghost) * 0.055
                    guard gPhase >= 0, gPhase <= 1 else { continue }
                    let x = size.width * (0.06 + 0.88 * gPhase)
                    let y = size.height * (0.5 + 0.3 * sin(gPhase * 2.6 * .pi))
                    let newness = 1 - Double(ghost) / Double(ghostCount + 1)
                    let radius = (4 + 5 * newness)
                    let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(dotColor.opacity(0.15 + 0.85 * newness * newness)))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
