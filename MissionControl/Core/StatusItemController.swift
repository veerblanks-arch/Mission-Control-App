import AppKit

final class StatusItemController: NSObject {
    private let overlayPanelController: OverlayPanelController
    private let onShowCommandMode: () -> Void
    private let onShowSettings: () -> Void
    private let onQuit: () -> Void
    private var statusItem: NSStatusItem?

    init(
        overlayPanelController: OverlayPanelController,
        onShowCommandMode: @escaping () -> Void,
        onShowSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.overlayPanelController = overlayPanelController
        self.onShowCommandMode = onShowCommandMode
        self.onShowSettings = onShowSettings
        self.onQuit = onQuit
    }

    func start() {
        guard statusItem == nil else {
            return
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "rectangle.on.rectangle.angled",
            accessibilityDescription: "Silverdeck"
        )
        item.button?.imagePosition = .imageOnly
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    func stop() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }

        statusItem = nil
    }

    func showClipboard(focusedItemID: UUID? = nil) {
        guard let button = statusItem?.button else {
            return
        }

        overlayPanelController.showClipboard(
            relativeTo: button,
            focusedItemID: focusedItemID
        )
    }

    func showCodex(threadID: String? = nil) {
        guard let button = statusItem?.button else { return }
        overlayPanelController.showCodex(relativeTo: button, threadID: threadID)
    }

    func showFeature(_ feature: OverlayFeature) {
        guard let button = statusItem?.button else { return }
        overlayPanelController.showFeature(feature, relativeTo: button)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showContextMenu()
            return
        }

        overlayPanelController.toggle(relativeTo: sender)
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(menuItem(title: "Open Silverdeck", action: #selector(openDroppy)))
        let commandMode = menuItem(
            title: "Command Mode",
            action: #selector(openCommandMode)
        )
        commandMode.keyEquivalent = " "
        commandMode.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(commandMode)
        menu.addItem(menuItem(title: "Settings", action: #selector(showSettings)))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Quit Silverdeck", action: #selector(quit), keyEquivalent: "q"))

        guard let button = statusItem?.button else {
            return
        }

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func menuItem(
        title: String,
        action: Selector,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    @objc private func openDroppy() {
        showOverlay()
    }

    @objc private func openCommandMode() {
        onShowCommandMode()
    }

    private func showOverlay() {
        guard let button = statusItem?.button else {
            return
        }

        overlayPanelController.show(relativeTo: button)
    }

    @objc private func showSettings() {
        onShowSettings()
    }

    @objc private func quit() {
        onQuit()
    }
}
