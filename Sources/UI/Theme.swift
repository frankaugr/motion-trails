import SwiftUI
import UIKit

/// Design tokens for the dark-first visual identity. Every screen draws from these instead of
/// stock defaults so the app reads as one cohesive creative tool: a near-black canvas, raised
/// dark surfaces, and the single trail-teal accent (the asset catalog's `AccentColor`).
enum Theme {
    /// Editor/canvas background — near-black, slightly blue.
    static let canvas = Color(red: 0.055, green: 0.055, blue: 0.067)
    /// Raised panels and cards over the canvas.
    static let surface = Color(red: 0.102, green: 0.106, blue: 0.125)
    /// Brighter fills for chips, tracks and secondary controls.
    static let surfaceBright = Color(red: 0.165, green: 0.17, blue: 0.196)
    /// Text on accent-filled controls (the accent is bright, so text goes dark).
    static let onAccent = Color(red: 0.016, green: 0.13, blue: 0.10)

    static let cornerRadius: CGFloat = 14
    static let panelRadius: CGFloat = 18

    /// Centralized haptics so feedback stays consistent (and easy to mute later).
    enum Haptics {
        static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        static func action() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
        static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        static func failure() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    }
}

/// Filled accent CTA used for the primary action on each screen.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Theme.onAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}
