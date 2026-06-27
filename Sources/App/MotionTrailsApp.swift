import SwiftUI
import UIKit

@main
struct MotionTrailsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Minimal app delegate whose only job is to gate supported interface orientations.
/// The app is otherwise free-orientation; the capture screen flips `orientationLock` to
/// `.portrait` while it's on screen (a `requestGeometryUpdate` alone can't constrain rotation —
/// iOS still consults the app's supported set, which is this).
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .all

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.orientationLock
    }
}
