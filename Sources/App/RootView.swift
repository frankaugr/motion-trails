import SwiftUI

/// A video file referenced by navigation. `URL` isn't `Identifiable`, so this thin wrapper
/// lets screens push each other via `navigationDestination(item:)`.
struct VideoRef: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
}

/// App root: owns the shared `ProjectStore` and hosts the project library.
struct RootView: View {
    @State private var store = ProjectStore()

    var body: some View {
        NavigationStack {
            LibraryView()
        }
        .environment(store)
        // Dark-first identity: the whole app lives on the dark canvas (creative tools read as
        // tools, not as Settings), with the trail-teal accent from the asset catalog.
        .preferredColorScheme(.dark)
    }
}

#Preview {
    RootView()
}
