import Foundation
import CoreGraphics

/// User-facing render controls plus the internal tunables they map to (spec §11.4, §7.5).
///
/// Detection is driven by a single high-level choice — `contrastMode` ("my subject is a dark
/// silhouette / a bright shape / a different colour / anything") — which bundles the concrete Core
/// Image tunables (difference threshold + morphology radius) so the UI never exposes a raw
/// sensitivity/min-size slider.
struct RenderSettings: Equatable, Hashable, Codable {
    /// What kind of subject-vs-background contrast counts as motion (spec §11.4). Letting the user
    /// name it ("a dark silhouette", "a bright shape on a dark background", "a different colour")
    /// lets the detector ignore the *other* kinds of change — e.g. `.silhouette` ignores drifting
    /// light clouds because they aren't a luminance *darkening*.
    var contrastMode: ContrastMode = .any

    /// How fast a subject must move to count as motion, in **seconds of source** (the detection
    /// "horizon" K). Detection is a short-horizon temporal difference — each frame is compared to the
    /// frames K seconds *before and after* it, not to the long-term background plate. Anything that
    /// barely moves over ±K (drifting clouds, a swaying tree, slow light changes) cancels out; only
    /// things that displace within ±K (the birds this app is built for) survive. Smaller = stricter
    /// (only the fastest subjects leave trails); larger = catches slower motion (but lets clouds
    /// back in). This is the crux control for fast-subject detection.
    var motionHorizonSeconds: Double = 0.25

    /// Apply Vision frame registration before motion detection (spec §11.3).
    ///
    /// Off by default: tripod clips drift little, and on low-feature scenes (e.g. open sky)
    /// translational registration can lock onto the moving subjects instead of the static
    /// background and corrupt the frame. Enable for genuinely handheld/shaky footage.
    var stabilizationEnabled: Bool = false

    /// What the trails composite **over** in the output (a display choice — detection is temporal and
    /// independent of this). `.frozen` = the static median plate (spec's frozen-scene look); `.live`
    /// = the moving scene, so clouds/foliage keep moving under the accumulating trails.
    var backgroundMode: BackgroundMode = .frozen

    /// Social crop/aspect applied to the export, after processing (spec §7.6, §11.1).
    var cropAspect: CropAspect = .original

    /// 0…1 trail frequency: how often a moving subject's silhouette is snapshotted into the
    /// trail (spec §7.5). Higher = more frequent snapshots = denser trail; lower spaces them out.
    var trailFrequency: Double = 1.0

    /// Output frame rate (spec §23 default 30).
    var outputFPS: Int = 30

    // MARK: - Creative effects (spec §8)

    /// How moving pixels combine into the accumulator (spec §9.2, §11.5).
    var trailMode: TrailMode = .replacement

    /// Seconds after a mark is left until it has faded back into the background (§11.5).
    /// 0 = off (persistent trails). Surfaced as the Fade slider, 0…10 s.
    var fadeSeconds: Double = 0

    /// Trail coloring (spec §8).
    var colorStyle: ColorStyle = .natural

    /// Seconds after a mark is left until its hue has shifted from `gradientNewest` to
    /// `gradientOldest` (`colorStyle == .ageGradient` only). Surfaced as the gradient-speed slider,
    /// 0.5…10 s. Deliberately independent of `fadeSeconds`: the colour age decays at its own rate
    /// (`gradientDecay`), so the hue can sweep while the trail itself stays fully opaque.
    var gradientShiftSeconds: Double = 2.0

    /// Age-gradient endpoints: a fresh mark appears as `gradientNewest` and shifts toward
    /// `gradientOldest` as it ages.
    var gradientNewest: GradientColor = .defaultNewest
    var gradientOldest: GradientColor = .defaultOldest

    /// A plain sRGB colour for the age gradient — `Codable`/`Hashable` so it can live in the
    /// settings manifest (SwiftUI/Core Image colour types are converted at the edges).
    struct GradientColor: Equatable, Hashable, Codable {
        var red: Double
        var green: Double
        var blue: Double

        static let defaultNewest = GradientColor(red: 1.00, green: 0.55, blue: 0.05)  // warm orange
        static let defaultOldest = GradientColor(red: 0.16, green: 0.30, blue: 0.92)  // cool blue
    }

    /// 0…1 simulated handheld-camera motion baked into the export (0 = locked-off, the default).
    /// Drives `HandheldMotion` — layered sway/correction/tremor noise, not a sine wobble. Display
    /// time only: it transforms the final composited frame, so detection and the preview's proxy
    /// layers are untouched (the editor canvas animates it live instead).
    var handheldAmount: Double = 0

    /// Depth parallax for the simulated handheld motion: larger trail marks (≈ nearer subjects)
    /// translate progressively more than small ones under the same camera sway, and can
    /// occlude/reveal what's behind them, the way real depth planes shift under parallax. The
    /// engine accumulates a separate transparent plane per size band and re-projects each with
    /// its own pushed offset (`TrailRenderEngine.parallaxBands`). Only meaningful when
    /// `handheldAmount > 0`; like the shake itself it is baked into the export, not the live
    /// preview.
    var handheldParallax: Bool = false

    /// Discrete handheld-motion presets exposed in the UI; each maps to a fixed `handheldAmount`.
    enum HandheldLevel: String, CaseIterable, Codable {
        case none, low, medium, high
        var label: String {
            switch self {
            case .none:   return "None"
            case .low:    return "Low"
            case .medium: return "Medium"
            case .high:   return "High"
            }
        }
        var amount: Double {
            switch self {
            case .none:   return 0.0
            case .low:    return 0.25
            case .medium: return 0.55
            case .high:   return 1.0
            }
        }
        static func nearest(to amount: Double) -> HandheldLevel {
            allCases.min(by: { abs($0.amount - amount) < abs($1.amount - amount) }) ?? .none
        }
    }

    var handheldLevel: HandheldLevel {
        get { HandheldLevel.nearest(to: handheldAmount) }
        set { handheldAmount = newValue.amount }
    }

    /// Normalized (0…1) rectangles to exclude from motion detection (spec §9.3).
    var ignoreRegions: [CGRect] = []

    /// Freehand brush strokes to exclude from motion detection, alongside `ignoreRegions`.
    var ignoreStrokes: [IgnoreStroke] = []

    /// A freehand exclusion stroke. `points` are normalized (0…1, **top-left origin** — the same
    /// UI convention as `ignoreRegions`); `radius` is normalized to the image **width**, so the
    /// stroke rasterizes as true circles of matching visual size at any resolution (the engine's
    /// full-res frame and the preview's proxy alike).
    struct IgnoreStroke: Equatable, Hashable, Codable {
        var points: [CGPoint]
        var radius: Double
    }

    /// The kind of contrast that distinguishes a moving subject from the static background.
    enum ContrastMode: String, CaseIterable, Identifiable, Codable {
        /// Any change from the background (full-colour difference) — the safe default.
        case any
        /// Dark subject over a brighter background (luminance darkening) — birds against the sky.
        case silhouette
        /// Bright subject over a darker background (luminance brightening) — white birds, headlights.
        case highlight
        /// Different colour at similar brightness (chroma difference) — a red coat on grey pavement.
        case colour

        var id: String { rawValue }

        var label: String {
            switch self {
            case .any: return "Any"
            case .silhouette: return "Silhouette"
            case .highlight: return "Highlight"
            case .colour: return "Colour"
            }
        }

        var caption: String {
            switch self {
            case .any: return "Detects any change from the background."
            case .silhouette: return "Dark subjects on a brighter background (e.g. birds against the sky). Ignores light-on-light change like drifting clouds."
            case .highlight: return "Light subjects on a darker background (e.g. white birds, headlights, splashes)."
            case .colour: return "Subjects that differ in colour but not brightness (e.g. a red coat on grey pavement)."
            }
        }

        /// Cutoff in 0…1 for `CIColorThreshold`, tuned per metric: `.colour` keys on subtler chroma
        /// differences so it sits lower, while `.any` is held a little stricter to tame the broad
        /// noise an undirected difference picks up.
        var differenceThreshold: Double {
            switch self {
            case .any: return 0.18
            case .silhouette: return 0.16
            case .highlight: return 0.16
            case .colour: return 0.10
            }
        }

        /// Circular morphology radius (full-resolution px; `radiusScale` shrinks it to the mask
        /// working space) for the opening (despeckle) pass.
        ///
        /// Kept small on purpose. With **temporal** detection the background is already clean (slow
        /// clouds/foliage never enter the signal), and the mask is built on a downscale-averaged
        /// working copy that has already soaked up most sensor speckle — the opening only has to
        /// kill single-pixel noise. A large circular structuring element here was the cause of
        /// "distant birds render as round dots": erode-then-dilate strips a small bird's wings down
        /// to its round body core, then re-inflates that into a disc (r6 did it at full res; even
        /// r2 — 1 px in the 960 working space — clipped thin wings at some flap phases). r1 hits
        /// the 0.5 px working-space floor that the preview's proxy has always used.
        var morphologyRadius: Double { 1.0 }
    }

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

    /// What the persistent trails are drawn over in the output. Detection no longer depends on this
    /// (it's temporal) — it's purely the display backdrop.
    enum BackgroundMode: String, CaseIterable, Identifiable, Codable {
        /// Trails over a frozen still (the temporal-median plate) — the static-scene look.
        /// rawValue kept as `"static"` so manifests written before the rename still decode.
        case frozen = "static"
        /// Trails over the live moving scene — clouds drift and foliage sways under the trail.
        case live

        var id: String { rawValue }
        var label: String {
            switch self {
            case .frozen: return "Frozen"
            case .live: return "Live"
            }
        }
        var caption: String {
            switch self {
            case .frozen: return "Trails sit over a frozen still of the scene."
            case .live: return "Trails sit over the live scene — clouds and foliage keep moving."
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

    /// Difference cutoff in 0...1 for `CIColorThreshold` — bundled into the chosen contrast mode.
    var differenceThreshold: Double { contrastMode.differenceThreshold }

    /// Circular morphology radius (working-resolution px) for the opening pass — from the mode.
    var morphologyRadius: Double { contrastMode.morphologyRadius }

    /// An exponential age decay never reaches 0, so "faded out in N seconds" means the age has
    /// dropped to this cutoff by then — ~5% reads as gone (fade) / as the end colour (gradient).
    private static let agedOutCutoff = 0.05

    /// The per-frame multiplier that takes an age from 1 down to `agedOutCutoff` over `seconds`
    /// of output. ≤ 0 seconds means no decay (1.0).
    static func decay(overSeconds seconds: Double, fps: Int) -> Double {
        guard seconds > 0 else { return 1 }
        return pow(agedOutCutoff, 1.0 / (Double(max(1, fps)) * seconds))
    }

    /// Per-frame multiplier applied to the age map. 1.0 = persistent (no fade); lower fades faster.
    var ageDecay: Double { Self.decay(overSeconds: fadeSeconds, fps: outputFPS) }

    /// Per-frame multiplier for the **colour** age map (gradient mode). Separate from `ageDecay` so
    /// the hue sweep is independent of the fade (the old behaviour reused the fade decay, which made
    /// the gradient a flat colour whenever fade was 0).
    var gradientDecay: Double { Self.decay(overSeconds: gradientShiftSeconds, fps: outputFPS) }

    /// Persistent trail snapshots per **second of source**, derived from the 0…1 `trailFrequency`
    /// (spec §7.5). Time-based on purpose: the old model spread a fixed count across the whole clip,
    /// so the same "Dense" setting produced a tight trail on a 5 s clip and a sparse one on a 45 s
    /// clip. Anchoring to seconds keeps the trail's temporal density identical regardless of length.
    var snapshotsPerSecond: Double {
        let sparsest = 0.5    // freq 0 → one snapshot every 2 s
        let densest = 10.0   // freq 1 → 10 snapshots/s (every 0.1 s)
        let f = min(max(trailFrequency, 0), 1)
        return sparsest + (densest - sparsest) * f
    }

    /// Seconds between persistent trail snapshots — the inverse of `snapshotsPerSecond`. Surfaced in
    /// the UI so the density slider reads in time units.
    var snapshotIntervalSeconds: Double { 1.0 / snapshotsPerSecond }

    /// Number of evenly-spaced snapshots for a clip of `durationSeconds`. Both the engine render and
    /// the live preview derive their density from this so they stay matched.
    func snapshotCount(durationSeconds: Double) -> Int {
        max(1, Int((max(0, durationSeconds) * snapshotsPerSecond).rounded()))
    }

    /// The detection horizon K in **frames** for a given source frame rate (≥ 1). The temporal
    /// detector compares each frame to the frames ±this many positions away.
    func motionHorizonFrames(fps: Double) -> Int {
        max(1, Int((motionHorizonSeconds * max(1, fps)).rounded()))
    }

    /// Stable textual fingerprint of the ignore geometry (rects + strokes), shared by the edit
    /// screen's `maskKey` and the preview's on-disk `cacheKey` so they can't drift apart.
    var ignoreFingerprint: String {
        var parts = ignoreRegions.map {
            String(format: "r%.3f,%.3f,%.3f,%.3f", $0.minX, $0.minY, $0.width, $0.height)
        }
        parts += ignoreStrokes.map { stroke in
            String(format: "s%.4f:", stroke.radius)
                + stroke.points.map { String(format: "%.3f,%.3f", $0.x, $0.y) }.joined(separator: " ")
        }
        return parts.joined(separator: ";")
    }
}

// MARK: - Schema-tolerant decoding

/// Custom `Decodable` so stored project manifests survive settings being added or removed across
/// versions (missing keys fall back to defaults; unknown keys like a removed `outputSpeed` are
/// ignored). `Encodable` and the memberwise initializer stay synthesized.
extension RenderSettings {
    enum CodingKeys: String, CodingKey {
        case contrastMode, motionHorizonSeconds, stabilizationEnabled, backgroundMode, cropAspect
        case trailMode, fadeSeconds, colorStyle, handheldAmount, handheldParallax, ignoreRegions, ignoreStrokes
        case trailFrequency, outputFPS
        case gradientShiftSeconds, gradientNewest, gradientOldest
    }

    /// Pre-seconds keys: `fadeAmount`/`gradientSpeed` were 0…1 knobs mapped linearly to a per-frame
    /// decay. Decoded (and converted to the equivalent seconds) so old manifests keep their look.
    /// Kept out of `CodingKeys` so the synthesized `Encodable` never writes them back.
    private enum LegacyKeys: String, CodingKey {
        case fadeAmount, gradientSpeed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var s = RenderSettings()
        s.contrastMode = try c.decodeIfPresent(ContrastMode.self, forKey: .contrastMode) ?? s.contrastMode
        s.motionHorizonSeconds = try c.decodeIfPresent(Double.self, forKey: .motionHorizonSeconds) ?? s.motionHorizonSeconds
        s.stabilizationEnabled = try c.decodeIfPresent(Bool.self, forKey: .stabilizationEnabled) ?? s.stabilizationEnabled
        // Tolerant: a removed raw value (e.g. the old "slowUpdate") decodes to nil → default, instead
        // of throwing and failing the whole manifest.
        s.backgroundMode = ((try? c.decodeIfPresent(BackgroundMode.self, forKey: .backgroundMode)) ?? nil) ?? s.backgroundMode
        s.cropAspect = try c.decodeIfPresent(CropAspect.self, forKey: .cropAspect) ?? s.cropAspect
        s.trailMode = try c.decodeIfPresent(TrailMode.self, forKey: .trailMode) ?? s.trailMode
        s.fadeSeconds = try c.decodeIfPresent(Double.self, forKey: .fadeSeconds) ?? s.fadeSeconds
        s.colorStyle = try c.decodeIfPresent(ColorStyle.self, forKey: .colorStyle) ?? s.colorStyle
        s.gradientShiftSeconds = try c.decodeIfPresent(Double.self, forKey: .gradientShiftSeconds) ?? s.gradientShiftSeconds
        s.gradientNewest = try c.decodeIfPresent(GradientColor.self, forKey: .gradientNewest) ?? s.gradientNewest
        s.gradientOldest = try c.decodeIfPresent(GradientColor.self, forKey: .gradientOldest) ?? s.gradientOldest
        s.handheldAmount = try c.decodeIfPresent(Double.self, forKey: .handheldAmount) ?? s.handheldAmount
        s.handheldParallax = try c.decodeIfPresent(Bool.self, forKey: .handheldParallax) ?? s.handheldParallax
        s.ignoreRegions = try c.decodeIfPresent([CGRect].self, forKey: .ignoreRegions) ?? s.ignoreRegions
        s.ignoreStrokes = try c.decodeIfPresent([IgnoreStroke].self, forKey: .ignoreStrokes) ?? s.ignoreStrokes
        s.trailFrequency = try c.decodeIfPresent(Double.self, forKey: .trailFrequency) ?? s.trailFrequency
        s.outputFPS = try c.decodeIfPresent(Int.self, forKey: .outputFPS) ?? s.outputFPS

        // Legacy 0…1 knobs → the seconds that produce the same per-frame decay, so an old
        // manifest's tuned look survives the schema change.
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        if (try? c.decodeIfPresent(Double.self, forKey: .fadeSeconds)) == nil,
           let amount = try? legacy.decodeIfPresent(Double.self, forKey: .fadeAmount), amount > 0 {
            s.fadeSeconds = Self.seconds(forDecay: 1.0 - min(max(amount, 0), 1) * 0.1, fps: s.outputFPS)
        }
        if (try? c.decodeIfPresent(Double.self, forKey: .gradientShiftSeconds)) == nil,
           let speed = try? legacy.decodeIfPresent(Double.self, forKey: .gradientSpeed) {
            s.gradientShiftSeconds = Self.seconds(forDecay: 0.995 - min(max(speed, 0), 1) * 0.095,
                                                  fps: s.outputFPS)
        }
        self = s
    }

    /// Inverse of `decay(overSeconds:fps:)`, clamped to the sliders' 0…10 s range.
    private static func seconds(forDecay decay: Double, fps: Int) -> Double {
        guard decay > 0, decay < 1 else { return 0 }
        return min(10, log(agedOutCutoff) / (Double(max(1, fps)) * log(decay)))
    }
}
