import AppKit
import QuartzCore
import StashMacOSCore
import SwiftUI

final class OverlayWindowController: NSWindowController, NSWindowDelegate {
    private let viewModel: OverlayViewModel
    private let panel: OverlayPanel
    private var projectPopover: NSPopover?
    private var workspaceWindowControllers: [String: ProjectWorkspaceWindowController] = [:]
    private var shouldPresentProjectPickerOnActivate = false

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
        hostingView.onActivationClick = { [weak self] in
            self?.handleOverlayInteraction()
        }

        viewModel.stateDidChange = { [weak self] in
            self?.updateAppearance(animated: true)
        }
        viewModel.overlayTapped = { [weak self] in
            self?.handleOverlayInteraction()
        }
        viewModel.filesDropped = { [weak self] urls in
            self?.handleFilesDropped(urls)
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
        guard shouldPresentProjectPickerOnActivate else { return }
        shouldPresentProjectPickerOnActivate = false
        DispatchQueue.main.async { [weak self] in
            self?.presentProjectPickerPopover()
        }
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

    private func handleFilesDropped(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task { [weak self] in
            await self?.processDroppedFiles(urls)
        }
    }

    @MainActor
    private func processDroppedFiles(_ urls: [URL]) async {
        panel.makeKeyAndOrderFront(nil)
        shouldPresentProjectPickerOnActivate = false
        NSApp.activate(ignoringOtherApps: true)

        do {
            let project = try await viewModel.backendClient.ensureProjectSelection(
                preferredProjectID: viewModel.selectedProject?.id
            )
            projectPopover?.performClose(nil)
            openWorkspaceWindow(for: project)
            try await viewModel.backendClient.registerAssets(urls: urls, projectID: project.id)
        } catch {
            print("Asset drop handling failed: \(error)")
        }
    }

    @MainActor
    private func handleOverlayInteraction() {
        if panel.isKeyWindow {
            presentProjectPickerPopover()
            return
        }

        shouldPresentProjectPickerOnActivate = true
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    private func presentProjectPickerPopover() {
        if let projectPopover, projectPopover.isShown {
            return
        }

        guard let anchorView = panel.contentView else { return }

        let pickerViewModel = ProjectPickerViewModel(
            client: viewModel.backendClient,
            selectedProjectID: viewModel.selectedProject?.id
        )
        pickerViewModel.onPreferredPopoverSizeChange = { [weak self] size in
            self?.projectPopover?.contentSize = NSSize(width: size.width, height: size.height)
        }
        pickerViewModel.onProjectSelected = { [weak self] project in
            guard let self else { return }
            self.viewModel.selectedProject = project
            self.projectPopover?.performClose(nil)
            self.openWorkspaceWindow(for: project)
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let initialSize = pickerViewModel.preferredPopoverSize
        popover.contentSize = NSSize(width: initialSize.width, height: initialSize.height)
        popover.contentViewController = NSHostingController(rootView: ProjectPickerView(viewModel: pickerViewModel))
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
        projectPopover = popover
    }

    @MainActor
    private func openWorkspaceWindow(for project: OverlayProject) {
        viewModel.selectedProject = project

        if let existing = workspaceWindowControllers[project.id] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = ProjectWorkspaceWindowController(project: project)
        controller.onWindowClosed = { [weak self] projectID in
            self?.workspaceWindowControllers.removeValue(forKey: projectID)
        }
        workspaceWindowControllers[project.id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    private var initialLocation: NSPoint = .zero
    var onActivationClick: (() -> Void)?

    required init(rootView: Content) {
        onActivationClick = nil
        super.init(rootView: rootView)
    }

    convenience init(rootView: Content, onActivationClick: (() -> Void)? = nil) {
        self.init(rootView: rootView)
        self.onActivationClick = onActivationClick
    }

    required init?(coder: NSCoder) {
        onActivationClick = nil
        super.init(coder: coder)
    }

    override func mouseDown(with event: NSEvent) {
        let wasKeyWindow = window?.isKeyWindow ?? false
        initialLocation = event.locationInWindow
        window?.makeKeyAndOrderFront(nil)
        if !wasKeyWindow {
            onActivationClick?()
        }
        super.mouseDown(with: event)
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
