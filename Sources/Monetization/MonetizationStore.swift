import Foundation
import Observation

/// Premium entitlement + free-tier limits (spec §8, §13).
///
/// Stubbed for now: `isPremium` is persisted in `UserDefaults` and flipped by `purchasePremium()`.
/// The public surface (entitlement flag, limits, purchase/restore) matches what a StoreKit 2
/// implementation would expose, so real in-app purchases can drop in behind it later without
/// touching the UI or gating logic.
@Observable
final class MonetizationStore {
    private static let premiumKey = "com.frank.motiontrails.isPremium"

    var isPremium: Bool {
        didSet { UserDefaults.standard.set(isPremium, forKey: Self.premiumKey) }
    }

    init() {
        isPremium = UserDefaults.standard.bool(forKey: Self.premiumKey)
    }

    // MARK: - Free-tier limits (locked: 5s free / 60s premium)

    /// Hard recording cap for the free tier, in seconds (spec §7.1).
    let freeRecordingLimit: Double = 5
    /// Recording cap once premium is unlocked, in seconds.
    let premiumRecordingLimit: Double = 60

    var maxRecordingDuration: Double { isPremium ? premiumRecordingLimit : freeRecordingLimit }

    /// Free exports carry a watermark (spec §7.6, §13).
    var watermarkEnabled: Bool { !isPremium }

    /// Output long-edge cap (spec §8, §16): free is 1080p; premium allows up to 4K.
    var maxOutputDimension: CGFloat { isPremium ? 3840 : 1920 }

    /// Whether premium creative effects (fade/blend, color, ignore masks) are available.
    var premiumEffectsUnlocked: Bool { isPremium }

    // MARK: - Purchase (stub)

    /// Unlocks premium. Replace with a StoreKit 2 `Product.purchase()` + entitlement check.
    func purchasePremium() { isPremium = true }

    /// Restores prior purchases. A real impl iterates `Transaction.currentEntitlements`.
    func restore() {
        // Stub: nothing to restore in the local entitlement model.
    }
}
