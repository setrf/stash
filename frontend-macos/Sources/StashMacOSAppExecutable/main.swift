import SwiftUI
import StashMacOSCore

@main
struct StashDesktopApp: App {
    var body: some Scene {
        WindowGroup("Stash") {
            RootView()
                .frame(minWidth: 1240, minHeight: 820)
                .preferredColorScheme(.light)
        }
        .windowResizability(.contentSize)
    }
}
