import SwiftUI
import StashMacOSCore

@main
struct StashMacOSApp: App {
    var body: some Scene {
        WindowGroup("Stash") {
            RootView()
                .frame(minWidth: 1240, minHeight: 820)
                .preferredColorScheme(.light)
        }
        .windowResizability(.contentSize)
    }
}
