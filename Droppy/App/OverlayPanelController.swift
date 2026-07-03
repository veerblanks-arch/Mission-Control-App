import AppKit
import SwiftUI

final class OverlayPanelController: NSWindowController, NSWindowDelegate {
    private enum Constants {
        static let defaultSize = NSSize(width: 420, height: 560)
        static let minimumSize = NSSize(width: 360, height: 420)
        static let topPadding: CGFloat = 8
    }

    private var lastStatusButton: NSStatusBarButton?
    private let model = OverlayPanelModel()

    init() {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Constants.defaultSize),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Droppy"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.minSize = Constants.minimumSize
        panel.contentViewController = NSHostingController(
            rootView: OverlayRootView(
                model: model,
                clipboardManager: .shared
            )
        )

        super.init(window: panel)

        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func toggle(relativeTo statusButton: NSStatusBarButton) {
        if window?.isVisible == true {
            close()
        } else {
            show(relativeTo: statusButton)
        }
    }

    func show(relativeTo statusButton: NSStatusBarButton) {
        lastStatusButton = statusButton
        positionPanel(relativeTo: statusButton)
        showWindow(nil)
        window?.orderFrontRegardless()
    }

    func showClipboard(relativeTo statusButton: NSStatusBarButton) {
        model.selectedFeature = .clipboard
        show(relativeTo: statusButton)
    }

    func windowDidResize(_ notification: Notification) {
        guard let lastStatusButton else {
            return
        }

        positionPanel(relativeTo: lastStatusButton)
    }

    private func positionPanel(relativeTo statusButton: NSStatusBarButton) {
        guard
            let window,
            let buttonWindow = statusButton.window,
            let screen = buttonWindow.screen ?? NSScreen.main
        else {
            return
        }

        let buttonFrame = statusButton.convert(statusButton.bounds, to: nil)
        let buttonFrameOnScreen = buttonWindow.convertToScreen(buttonFrame)
        var panelFrame = window.frame
        if panelFrame.size == .zero {
            panelFrame.size = Constants.defaultSize
        }

        let visibleFrame = screen.visibleFrame
        panelFrame.origin.x = buttonFrameOnScreen.midX - panelFrame.width / 2
        panelFrame.origin.y = buttonFrameOnScreen.minY - panelFrame.height - Constants.topPadding
        panelFrame.origin.x = min(max(panelFrame.origin.x, visibleFrame.minX + 12), visibleFrame.maxX - panelFrame.width - 12)
        panelFrame.origin.y = max(panelFrame.origin.y, visibleFrame.minY + 12)
        window.setFrame(panelFrame, display: true)
    }
}

final class OverlayPanelModel: ObservableObject {
    @Published var selectedFeature: OverlayFeature = .clipboard
}
