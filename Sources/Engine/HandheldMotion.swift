import CoreGraphics
import CoreImage
import Foundation

/// Procedural handheld-camera motion: makes a locked-off tripod shot read as handheld by sampling
/// a smooth, non-repeating camera pose over time and re-projecting each frame through it.
///
/// Built to avoid the "lazy sine wobble" look. Measured handheld footage (gyro studies, Unity
/// Cinemachine's recorded handheld noise profiles) has three distinct frequency bands, with
/// amplitude falling as frequency rises:
///  - slow postural sway / breathing drift (~0.3 Hz) — the largest excursions,
///  - voluntary framing corrections (~1–2 Hz) — medium,
///  - physiological hand tremor (~8–12 Hz) — tiny.
/// Real shake is also dominated by *rotation*, not translation: in a 2-D re-projection the
/// camera's yaw/pitch map to image translation (small-angle), so the x/y offsets here *are* that
/// rotational sway; roll is applied as true in-plane rotation, which is what sells handheld.
///
/// Each axis sums the three bands of 1-D value noise with C2 (quintic) interpolation — continuous
/// position *and* velocity, so no per-frame "earthquake" jitter and no mechanical sine
/// periodicity; the band frequencies are mutually irrational so the pattern never visibly
/// repeats. The lattice is seeded deterministically, so re-rendering the same settings produces
/// the same output.
struct HandheldMotion: Equatable {

    /// Camera pose offset at one instant, in the **engine's y-up image space**: offsets are
    /// fractions of the frame *width* (resolution-independent; the same fraction reads the same
    /// at proxy and export scale), roll is radians counter-clockwise. View-layer consumers
    /// (SwiftUI is y-down with clockwise angles) must negate `offsetY` and `roll`.
    struct Pose {
        var offsetX: Double
        var offsetY: Double
        var roll: Double
    }

    /// 0…1 — drives excursion *size* first and pace only gently: amplitudes scale linearly, while
    /// the band frequencies scale a modest ±15% around the midpoint (`frequencyScale`). A steadier
    /// hand moves less and a touch more lazily; a shakier one bigger and slightly more nervous —
    /// but magnitude is the headline change, not speed.
    let intensity: Double

    /// (frequency Hz, weight) per band: sway / corrections / tremor. Weights sum to 1, so each
    /// axis's summed noise is bounded by ±1 and the `overscan` guarantee below is exact.
    ///
    /// The weights are *amplitude* shares, but what the eye reads is **velocity** — amplitude ×
    /// frequency — so the high-frequency tremor must be weighted tiny or it dominates the look
    /// (at 0.11 it carried ~5× the sway's apparent motion and the result read as buzzing, not
    /// swaying). At these weights the three bands contribute roughly equal velocity, while the
    /// excursions themselves stay sway-dominated.
    private static let bands: [(frequency: Double, weight: Double)] = [
        (0.31, 0.75),
        (1.37, 0.22),
        (9.70, 0.03),
    ]

    /// Gentle pace response to the slider: ×0.85 at intensity 0 → ×1.15 at intensity 1.
    private var frequencyScale: Double { 0.85 + 0.3 * intensity }

    /// Largest translation excursion at intensity 1, as a fraction of frame width (~1.8%).
    private static let maxOffsetFraction = 0.018
    /// Vertical excursions run slightly larger than horizontal — breathing bob beats side sway.
    private static let verticalBias = 1.15
    /// Largest roll excursion at intensity 1 (radians, ≈ 0.9°). Kept small: visible roll is the
    /// fastest way to overshoot from "handheld" into "drunk".
    private static let maxRollRadians = 0.016

    func pose(at t: Double) -> Pose {
        let amplitude = Self.maxOffsetFraction * intensity
        return Pose(offsetX: amplitude * layered(t, seed: 0x6878),
                    offsetY: amplitude * Self.verticalBias * layered(t, seed: 0x6879),
                    roll: Self.maxRollRadians * intensity * layered(t, seed: 0x6872))
    }

    /// Zoom-in factor about the frame centre that guarantees the worst-case translated + rolled
    /// frame still covers `size` — no border is ever revealed, so `apply` needs no edge clamping.
    /// (Containment condition: `size` inverse-rotated by max roll has bounding box
    /// `(w·cosθ + h·sinθ, w·sinθ + h·cosθ)`; add twice the max translation magnitude per axis.)
    func overscan(for size: CGSize) -> CGFloat {
        let w = Double(size.width), h = Double(size.height)
        guard w > 0, h > 0 else { return 1 }
        let theta = Self.maxRollRadians * intensity
        let tMax = Self.maxOffsetFraction * intensity * w
            * (1.0 + Self.verticalBias * Self.verticalBias).squareRoot()
        let coverW = (w * cos(theta) + h * sin(theta) + 2 * tMax) / w
        let coverH = (w * sin(theta) + h * cos(theta) + 2 * tMax) / h
        return CGFloat(max(coverW, coverH) * 1.002)   // hair of margin for resampling
    }

    /// Re-projects a full composited frame through the pose at `t`: zoom by the safe overscan
    /// about the frame centre, roll, then shift. Cropped back to `frameRect` the result has no
    /// exposed edges by construction. Subpixel resampling softens the frame very slightly —
    /// which is authentic for handheld.
    ///
    /// `parallax` scales the **translation only** (`offset × (1 + parallax)`), never the roll or
    /// the overscan zoom: in-plane camera roll shifts every depth identically, so a nearer depth
    /// plane differs purely in how far it translates — scaling roll or zoom would instead
    /// misregister the plane against the scene. The overscan no-border guarantee holds for
    /// `parallax == 0` only; a pushed plane can translate past its covered border, so pass
    /// `parallax > 0` only for transparent-backed layers (the engine's near trail planes —
    /// `TrailRenderEngine.parallaxBands`), never the opaque base frame.
    func apply(to image: CIImage, at t: Double, frameRect: CGRect, parallax: Double = 0) -> CIImage {
        guard intensity > 0 else { return image }
        let p = pose(at: t)
        let s = overscan(for: frameRect.size)
        let push = 1 + parallax
        let transform = CGAffineTransform(translationX: frameRect.midX + p.offsetX * push * frameRect.width,
                                          y: frameRect.midY + p.offsetY * push * frameRect.width)
            .rotated(by: p.roll)
            .scaledBy(x: s, y: s)
            .translatedBy(x: -frameRect.midX, y: -frameRect.midY)
        return image.transformed(by: transform).cropped(to: frameRect)
    }

    // MARK: - Noise

    /// The three bands summed for one axis; bounded by ±1 (weights sum to 1).
    private func layered(_ t: Double, seed: UInt64) -> Double {
        var total = 0.0
        for (i, band) in Self.bands.enumerated() {
            total += band.weight * Self.valueNoise(t * band.frequency * frequencyScale,
                                                   seed: seed &+ UInt64(i &+ 1) &* 0x9E3779B97F4A7C15)
        }
        return total
    }

    /// 1-D value noise: random lattice values, quintic (C2) interpolation between them — smooth
    /// position and velocity, unlike per-frame random jitter; aperiodic, unlike a sine.
    private static func valueNoise(_ t: Double, seed: UInt64) -> Double {
        let cell = floor(t)
        let f = t - cell
        let u = f * f * f * (f * (f * 6 - 15) + 10)
        let a = lattice(Int64(cell), seed: seed)
        let b = lattice(Int64(cell) + 1, seed: seed)
        return a + (b - a) * u
    }

    /// Deterministic lattice value in [-1, 1) (splitmix64 finalizer).
    private static func lattice(_ i: Int64, seed: UInt64) -> Double {
        var x = UInt64(bitPattern: i) &+ seed &* 0xBF58476D1CE4E5B9
        x ^= x >> 30; x &*= 0xBF58476D1CE4E5B9
        x ^= x >> 27; x &*= 0x94D049BB133111EB
        x ^= x >> 31
        return Double(x >> 11) * (2.0 / 9007199254740992.0) - 1.0
    }
}
