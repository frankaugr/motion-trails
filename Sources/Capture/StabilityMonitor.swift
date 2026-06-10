import CoreMotion
import Observation

/// Pre-capture stability check (spec §7.3, §12.2). Samples the gyroscope and classifies how
/// steady the device is, so the capture screen can warn about handheld/shaky setups. Advisory
/// only — it never blocks recording.
@Observable
final class StabilityMonitor {
    enum Stability {
        case unknown, stable, minor, unstable

        var label: String {
            switch self {
            case .unknown: return "Checking…"
            case .stable: return "Stable"
            case .minor: return "Minor movement"
            case .unstable: return "Unstable — use a tripod"
            }
        }
        var systemImage: String {
            switch self {
            case .unknown: return "gyroscope"
            case .stable: return "checkmark.circle.fill"
            case .minor: return "exclamationmark.triangle.fill"
            case .unstable: return "exclamationmark.octagon.fill"
            }
        }
    }

    private(set) var stability: Stability = .unknown
    /// Device tilt from portrait-upright, in degrees (gravity-derived). Drives the capture
    /// screen's level indicator: 0° = a level framing.
    private(set) var tiltDegrees: Double = 0

    private let motion = CMMotionManager()
    private var samples: [Double] = []

    func start() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30.0
        motion.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let r = motion.rotationRate
            let magnitude = (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot()  // rad/s
            self.samples.append(magnitude)
            if self.samples.count > 30 { self.samples.removeFirst() }
            self.classify()

            // Portrait-upright gravity is (0, -1, 0); the x component reads sideways lean.
            let g = motion.gravity
            self.tiltDegrees = atan2(g.x, -g.y) * 180 / .pi
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        samples.removeAll()
        stability = .unknown
        tiltDegrees = 0
    }

    private func classify() {
        guard samples.count >= 10 else { return }
        let average = samples.reduce(0, +) / Double(samples.count)
        if average < 0.03 {
            stability = .stable
        } else if average < 0.12 {
            stability = .minor
        } else {
            stability = .unstable
        }
    }
}
