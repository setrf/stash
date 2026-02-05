import AppKit
import StashMacOSCore
import SwiftUI

final class ProjectWorkspaceWindowController: NSWindowController, NSWindowDelegate {
    let projectID: String
    var onWindowClosed: ((String) -> Void)?

    init(project: OverlayProject) {
        projectID = project.id

        let hostingController = NSHostingController(
            rootView: RootView(initialProjectRootPath: project.rootPath)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Stash - \(project.name)"
        window.minSize = NSSize(width: 980, height: 700)
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        nil
    }

    func windowWillClose(_ notification: Notification) {
        onWindowClosed?(projectID)
    }
}
