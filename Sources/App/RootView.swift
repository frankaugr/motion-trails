import SwiftUI

/// A video file referenced by navigation. `URL` isn't `Identifiable`, so this thin wrapper
/// lets screens push each other via `navigationDestination(item:)`.
struct VideoRef: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
}

/// App root: owns the shared `ProjectStore` + `MonetizationStore` and hosts the project library.
struct RootView: View {
    @State private var store = ProjectStore()
    @State private var monetization = MonetizationStore()

    var body: some View {
        NavigationStack {
            LibraryView()
        }
        .environment(store)
        .environment(monetization)
    }
}

#Preview {
    RootView()
}
