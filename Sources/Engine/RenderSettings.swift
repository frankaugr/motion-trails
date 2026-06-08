import Foundation
import CoreGraphics

/// User-facing render controls plus the internal tunables they map to (spec §11.4, §7.5).
///
/// The two primary sliders (`sensitivity`, `minMotionSize`) are kept in a neutral 0...1
/// range; the engine derives concrete pixel/threshold values from them so the UI never
/// has to know about Core Image internals.
struct RenderSettings: Equatable, Hashable, Codable {
    /// 0...1. Higher detects subtler motion (maps to a lower difference threshold).
    var sensitivity: Double = 0.55

    /// 0...1. Higher removes larger speckles / requires bigger subjects (bigger morphology radius).
    var minMotionSize: Double = 0.30

    /// Apply Vision frame registration before motion detection (spec §11.3).
    ///
    /// Off by default: tripod clips drift little, and on low-feature scenes (e.g. open sky)
    /// translational registration can lock onto the moving subjects instead of the static
    /// background and corrupt the frame. Enable for genuinely handheld/shaky footage.
    var stabilizationEnabled: Bool = false

    /// Background reference behavior. The prototype renders with `.static`.
    var backgroundMode: BackgroundMode = .static

    /// Social crop/aspect applied to the export, after processing (spec §7.6, §11.1).
    var cropAspect: CropAspect = .original

    /// Playback speed of the accumulated trail (spec §7.5). 1.0 = real time; >1 builds faster.
    var outputSpeed: Double = 1.0

    /// Output frame rate (spec §23 default 30).
    var outputFPS: Int = 30

    // MARK: - Premium (Phase 3, spec §8)

    /// How moving pixels combine into the accumulator (spec §9.2, §11.5).
    var trailMode: TrailMode = .replacement

    /// 0…1. 0 = persistent trails; higher fades older trails back toward the background (§11.5).
    var fadeAmount: Double = 0

    /// Trail coloring (spec §8).
    var colorStyle: ColorStyle = .natural

    /// Normalized (0…1) rectangles to exclude from motion detection (spec §9.3).
    var ignoreRegions: [CGRect] = []

    enum TrailMode: String, CaseIterable, Identifiable, Codable {
        case replacement
        case overlay
        var id: String { rawValue }
        var label: String { self == .replacement ? "Replace" : "Overlay" }
    }

    enum ColorStyle: String, CaseIterable, Identifiable, Codable {
        case natural
        case ageGradient
        var id: String { rawValue }
        var label: String { self == .natural ? "Natural" : "Age gradient" }
    }

    enum BackgroundMode: String, CaseIterable, Identifiable, Codable {
        case `static`
        case slowUpdate

        var id: String { rawValue }
        var label: String {
            switch self {
            case .static: return "Static"
            case .slowUpdate: return "Slow update"
            }
        }
    }

    /// Social aspect-ratio presets (spec §7.6). `original` keeps the source aspect.
    enum CropAspect: String, CaseIterable, Identifiable, Codable {
        case original
        case vertical9x16
        case square1x1
        case portrait4x5
        case landscape16x9

        var id: String { rawValue }

        var label: String {
            switch self {
            case .original: return "Original"
            case .vertical9x16: return "9:16"
            case .square1x1: return "1:1"
            case .portrait4x5: return "4:5"
            case .landscape16x9: return "16:9"
            }
        }

        /// Target width/height ratio, or `nil` to keep the source aspect.
        var ratio: CGFloat? {
            switch self {
            case .original: return nil
            case .vertical9x16: return 9.0 / 16.0
            case .square1x1: return 1.0
            case .portrait4x5: return 4.0 / 5.0
            case .landscape16x9: return 16.0 / 9.0
            }
        }

        /// Centered crop rect (even dimensions, H.264-safe) for this aspect within `fullSize`.
        func cropRect(in fullSize: CGSize) -> CGRect {
            guard let ratio else { return CGRect(origin: .zero, size: fullSize) }
            let fullRatio = fullSize.width / fullSize.height
            var w = fullSize.width
            var h = fullSize.height
            if ratio > fullRatio {
                h = fullSize.width / ratio      // target wider → limited by width
            } else {
                w = fullSize.height * ratio     // target taller → limited by height
            }
            let ew = CGFloat(max(2, Int(w.rounded()) & ~1))
            let eh = CGFloat(max(2, Int(h.rounded()) & ~1))
            let x = ((fullSize.width - ew) / 2).rounded(.down)
            let y = ((fullSize.height - eh) / 2).rounded(.down)
            return CGRect(x: x, y: y, width: ew, height: eh)
        }
    }

    // MARK: - Derived tunables

    /// Luminance/color difference cutoff in 0...1 for `CIColorThreshold`.
    /// Sensitivity inversely maps to threshold: more sensitive = lower cutoff.
    var differenceThreshold: Double {
        let strict = 0.30   // only large changes register
        let loose = 0.03    // subtle changes register
        return strict - (strict - loose) * sensitivity
    }

    /// Circular morphology radius (in working-resolution pixels) for the opening pass.
    var morphologyRadius: Double {
        1 + minMotionSize * 11   // 1px ... 12px
    }

    /// Per-frame multiplier applied to the age map. 1.0 = persistent (no fade); lower fades faster.
    var ageDecay: Double {
        1.0 - min(max(fadeAmount, 0), 1) * 0.1   // fadeAmount 0 → 1.0, 1 → 0.90
    }

}
