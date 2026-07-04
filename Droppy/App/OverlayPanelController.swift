import AppKit
import Combine
import SwiftUI

final class OverlayPanelController: NSWindowController, NSWindowDelegate {
    private enum Constants {
        static let collapsedSize = NSSize(width: 112, height: 24)
        static let expandedSize = NSSize(width: 420, height: 560)
        static let topPadding: CGFloat = 0
        static let screenEdgePadding: CGFloat = 12
    }

    private let model = OverlayPanelModel()
    private var cancellables: Set<AnyCancellable> = []
    private var anchorScreen: NSScreen?

    init() {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Constants.collapsedSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Droppy"
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.contentViewController = NSHostingController(
            rootView: OverlayRootView(
                model: model,
                clipboardManager: .shared
            )
        )

        super.init(window: panel)

        panel.delegate = self
        model.$isExpanded
            .dropFirst()
            .sink { [weak self] _ in
                self?.positionPanel(animated: true)
            }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func toggle(relativeTo statusButton: NSStatusBarButton) {
        updateAnchor(relativeTo: statusButton)

        if window?.isVisible == true {
            model.toggleExpanded()
        } else {
            model.collapse()
            show()
        }
    }

    func show(relativeTo statusButton: NSStatusBarButton) {
        updateAnchor(relativeTo: statusButton)
        show()
    }

    func showClipboard(relativeTo statusButton: NSStatusBarButton) {
        updateAnchor(relativeTo: statusButton)
        model.selectedFeature = .clipboard
        model.expand()
        show()
    }

    private func updateAnchor(relativeTo statusButton: NSStatusBarButton) {
        anchorScreen = statusButton.window?.screen ?? NSScreen.main
    }

    private func show() {
        positionPanel(animated: false)
        showWindow(nil)
        window?.orderFrontRegardless()
    }

    private func positionPanel(animated: Bool) {
        guard let window, let screen = anchorScreen ?? window.screen ?? NSScreen.main else {
            return
        }

        let size = model.isExpanded ? Constants.expandedSize : Constants.collapsedSize
        let screenFrame = screen.frame
        let menuBarHeight = max(screenFrame.maxY - screen.visibleFrame.maxY, Constants.collapsedSize.height)
        let collapsedTopInset = max((menuBarHeight - size.height) / 2, 0)
        let topInset = model.isExpanded ? Constants.topPadding : collapsedTopInset
        let topY = screenFrame.maxY - topInset
        var frame = NSRect(
            x: screenFrame.midX - size.width / 2,
            y: topY - size.height,
            width: size.width,
            height: size.height
        )
        frame.origin.x = min(
            max(frame.origin.x, screenFrame.minX + Constants.screenEdgePadding),
            screenFrame.maxX - frame.width - Constants.screenEdgePadding
        )
        frame.origin.y = max(frame.origin.y, screenFrame.minY + Constants.screenEdgePadding)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(frame, display: true)
            }
        } else {
            window.setFrame(frame, display: true)
        }
    }
}

final class OverlayPanelModel: ObservableObject {
    @Published var selectedFeature: OverlayFeature = .clipboard
    @Published private(set) var isExpanded = false

    func expand() {
        isExpanded = true
    }

    func collapse() {
        isExpanded = false
    }

    func toggleExpanded() {
        isExpanded.toggle()
    }
}
