import AppKit
import SwiftUI

private final class CommandModePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum CommandModeShortcutAction: Equatable {
    case openAndListen
    case startListening
    case endConversation
}

final class CommandModePanelController: NSWindowController {
    private let feature: CommandModeFeature
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var localKeyMonitor: Any?

    init(feature: CommandModeFeature) {
        self.feature = feature
        let panel = CommandModePanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 470),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Silverdeck Command Mode"
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false

        super.init(window: panel)

        feature.onDismiss = { [weak self] in self?.closeCommandMode() }
        panel.contentViewController = NSHostingController(
            rootView: CommandModeView(
                feature: feature,
                onDismiss: { [weak self] in self?.closeCommandMode() }
            )
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopDismissalMonitoring()
    }

    func handleGlobalShortcut() {
        switch Self.shortcutAction(
            isVisible: window?.isVisible == true,
            isListening: feature.conversation.isSessionActive
        ) {
        case .openAndListen:
            showCommandMode(startListening: true)
        case .startListening:
            feature.startVoiceFromShortcut()
        case .endConversation:
            feature.toggleVoice()
        }
    }

    func showCommandMode(startListening: Bool = false) {
        feature.prepareForPresentation()
        positionPanel()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        startDismissalMonitoring()
        if startListening {
            feature.startVoiceFromShortcut()
        }
    }

    func showCodexInteraction() {
        guard window?.isVisible == true else {
            showCommandMode()
            return
        }
        positionPanel()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        startDismissalMonitoring()
    }

    static func shortcutAction(
        isVisible: Bool,
        isListening: Bool
    ) -> CommandModeShortcutAction {
        guard isVisible else { return .openAndListen }
        return isListening ? .endConversation : .startListening
    }

    func closeCommandMode() {
        feature.cancelVoice()
        stopDismissalMonitoring()
        window?.orderOut(nil)
    }

    private func positionPanel() {
        guard let window else { return }
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
        guard let screen else { return }

        let size = window.frame.size
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - (size.width / 2),
            y: visible.maxY - size.height - 76
        )
        window.setFrameOrigin(origin)
    }

    private func startDismissalMonitoring() {
        stopDismissalMonitoring()

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.dismissIfOutside(at: NSEvent.mouseLocation)
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            self?.dismissIfOutside(at: NSEvent.mouseLocation)
            return event
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.closeCommandMode()
            return nil
        }
    }

    private func stopDismissalMonitoring() {
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        globalMouseMonitor = nil
        localMouseMonitor = nil
        localKeyMonitor = nil
    }

    private func dismissIfOutside(at point: NSPoint) {
        guard let window, window.isVisible, !window.frame.contains(point) else { return }
        guard !feature.conversation.isSessionActive else { return }
        closeCommandMode()
    }
}
