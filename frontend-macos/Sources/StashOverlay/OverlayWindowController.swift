import AppKit
import QuartzCore
import SwiftUI

final class OverlayWindowController: NSWindowController, NSWindowDelegate {
    private let viewModel: OverlayViewModel
    private let panel: OverlayPanel

    init(viewModel: OverlayViewModel) {
        self.viewModel = viewModel

        let contentRect = NSRect(x: 0, y: 0, width: 96, height: 96)
        let panel = OverlayPanel(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        self.panel = panel

        let rootView = OverlayRootView(viewModel: viewModel)
        let hostingView = DraggableHostingView(rootView: rootView)
        hostingView.frame = contentRect

        panel.contentView = hostingView
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false

        super.init(window: panel)
        panel.delegate = self

        viewModel.stateDidChange = { [weak self] in
            self?.updateAppearance(animated: true)
        }

        positionInitial()
        updateAppearance(animated: false)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.orderFrontRegardless()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        viewModel.isActive = true
    }

    func windowDidResignKey(_ notification: Notification) {
        viewModel.isActive = false
    }

    private func positionInitial() {
        guard let screenFrame = NSScreen.main?.visibleFrame else { return }
        let size = panel.frame.size
        let padding: CGFloat = 24
        let topOffset: CGFloat = 80
        let origin = NSPoint(
            x: screenFrame.maxX - size.width - padding,
            y: screenFrame.maxY - size.height - topOffset
        )
        panel.setFrameOrigin(origin)
    }

    private func updateAppearance(animated: Bool) {
        let engaged = viewModel.isEngaged
        let targetAlpha: CGFloat = engaged ? 1.0 : 0.55

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().alphaValue = targetAlpha
            }
        } else {
            panel.alphaValue = targetAlpha
        }
    }
}

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    private var initialLocation: NSPoint = .zero

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        initialLocation = event.locationInWindow
        window?.makeKey()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window = window else { return }
        let currentLocation = event.locationInWindow
        let deltaX = currentLocation.x - initialLocation.x
        let deltaY = currentLocation.y - initialLocation.y
        var newOrigin = window.frame.origin
        newOrigin.x += deltaX
        newOrigin.y += deltaY
        window.setFrameOrigin(newOrigin)
    }
}
