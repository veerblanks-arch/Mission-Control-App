import AppKit

final class MainTouchBarController: NSViewController, NSTouchBarDelegate {
    private enum Constants {
        static let touchBarIdentifier = NSTouchBar.CustomizationIdentifier("com.ranveer.droppy.touchbar.main")
        static let modalAutoMinimizeDelay: TimeInterval = 12
    }

    private var systemTrayItem: NSCustomTouchBarItem?
    private var activeModalTouchBar: NSTouchBar?
    private var modalAutoMinimizeTimer: Timer?

    func start() {
        registerSystemTrayItem()
    }

    func stop() {
        modalAutoMinimizeTimer?.invalidate()
        dismissModalTouchBar()
        unregisterSystemTrayItem()
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 120))
    }

    override func makeTouchBar() -> NSTouchBar? {
        makeModalTouchBar()
    }

    func presentModalTouchBar() {
        guard SystemModalTouchBarBridge.isSupported else {
            NSSound.beep()
            return
        }

        if systemTrayItem == nil {
            registerSystemTrayItem()
        }

        let touchBar = makeModalTouchBar()
        activeModalTouchBar = touchBar
        SystemModalTouchBarBridge.present(touchBar, systemTrayItemIdentifier: .droppySystemTray)
        scheduleModalAutoMinimize()
    }

    func dismissModalTouchBar() {
        modalAutoMinimizeTimer?.invalidate()
        modalAutoMinimizeTimer = nil

        if let activeModalTouchBar {
            SystemModalTouchBarBridge.dismiss(activeModalTouchBar)
        }

        activeModalTouchBar = nil
    }

    private func minimizeModalTouchBar() {
        modalAutoMinimizeTimer?.invalidate()
        modalAutoMinimizeTimer = nil

        if let activeModalTouchBar {
            SystemModalTouchBarBridge.minimize(activeModalTouchBar)
        }
    }

    private func registerSystemTrayItem() {
        guard SystemModalTouchBarBridge.isSupported, systemTrayItem == nil else {
            return
        }

        let item = NSCustomTouchBarItem(identifier: .droppySystemTray)
        let button = NSButton(
            image: NSImage(
                systemSymbolName: "rectangle.and.hand.point.up.left",
                accessibilityDescription: "Open Droppy Touch Bar"
            ) ?? NSImage(),
            target: self,
            action: #selector(systemTrayItemTapped)
        )
        button.bezelStyle = .texturedRounded
        button.toolTip = "Open Droppy"
        item.view = button
        item.customizationLabel = "Droppy"

        guard SystemModalTouchBarBridge.addSystemTrayItem(item) else {
            return
        }

        systemTrayItem = item
    }

    private func unregisterSystemTrayItem() {
        guard let systemTrayItem else {
            return
        }

        SystemModalTouchBarBridge.removeSystemTrayItem(systemTrayItem)
        self.systemTrayItem = nil
    }

    private func makeModalTouchBar() -> NSTouchBar {
        let touchBar = NSTouchBar()
        touchBar.delegate = self
        touchBar.customizationIdentifier = Constants.touchBarIdentifier
        touchBar.defaultItemIdentifiers = [
            .droppyControlsHeader,
            .droppyMedia,
            .droppyClipboard,
            .droppyShelf,
            .droppyCodexProfile,
            .droppyStats,
            .droppyTimer,
            .flexibleSpace,
            .droppyProfileStatus,
            .droppyMinimize,
            .droppyClose
        ]
        touchBar.customizationAllowedItemIdentifiers = touchBar.defaultItemIdentifiers
        touchBar.escapeKeyReplacementItemIdentifier = .droppyClose
        return touchBar
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        switch identifier {
        case .droppyControlsHeader:
            return controlsHeaderItem(identifier: identifier)
        case .droppyMedia:
            return iconButton(identifier: identifier, symbolName: "music.note", label: "Media")
        case .droppyClipboard:
            return iconButton(identifier: identifier, symbolName: "doc.on.clipboard", label: "Clipboard")
        case .droppyShelf:
            return iconButton(identifier: identifier, symbolName: "tray.and.arrow.down", label: "Shelf")
        case .droppyCodexProfile:
            return iconButton(identifier: identifier, symbolName: "folder.badge.gearshape", label: "Codex")
        case .droppyStats:
            return iconButton(identifier: identifier, symbolName: "cpu", label: "Stats")
        case .droppyTimer:
            return iconButton(identifier: identifier, symbolName: "timer", label: "Timer")
        case .droppyProfileStatus:
            return profileStatusItem(identifier: identifier)
        case .droppyMinimize:
            return actionButton(identifier: identifier, symbolName: "chevron.down", label: "Minimize", action: #selector(minimizeButtonTapped))
        case .droppyClose:
            return actionButton(identifier: identifier, symbolName: "xmark", label: "Close", action: #selector(closeButtonTapped))
        default:
            return nil
        }
    }

    private func controlsHeaderItem(identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: identifier)
        let label = NSTextField(labelWithString: "Droppy")
        label.alignment = .center
        label.font = .systemFont(ofSize: 12, weight: .bold)
        label.textColor = .systemTeal
        label.toolTip = "Droppy controls"
        item.view = label
        item.customizationLabel = "Droppy"
        return item
    }

    private func iconButton(
        identifier: NSTouchBarItem.Identifier,
        symbolName: String,
        label: String
    ) -> NSTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: identifier)
        let button = NSButton(
            image: NSImage(systemSymbolName: symbolName, accessibilityDescription: label) ?? NSImage(),
            target: nil,
            action: nil
        )
        button.bezelColor = .controlAccentColor
        button.toolTip = label
        item.view = button
        item.customizationLabel = label
        return item
    }

    private func actionButton(
        identifier: NSTouchBarItem.Identifier,
        symbolName: String,
        label: String,
        action: Selector
    ) -> NSTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: identifier)
        let button = NSButton(
            image: NSImage(systemSymbolName: symbolName, accessibilityDescription: label) ?? NSImage(),
            target: self,
            action: action
        )
        button.bezelStyle = .texturedRounded
        button.toolTip = label
        item.view = button
        item.customizationLabel = label
        return item
    }

    private func profileStatusItem(identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: identifier)
        let label = NSTextField(labelWithString: statusText)
        label.alignment = .center
        label.font = .systemFont(ofSize: 13, weight: .medium)
        item.view = label
        item.customizationLabel = "Status"
        return item
    }

    private var statusText: String {
        switch TouchBarProfileManager.shared.activeProfile {
        case .codex:
            return "Codex profile"
        case .default:
            return "Droppy ready"
        }
    }

    private func scheduleModalAutoMinimize() {
        modalAutoMinimizeTimer?.invalidate()
        modalAutoMinimizeTimer = Timer.scheduledTimer(
            withTimeInterval: Constants.modalAutoMinimizeDelay,
            repeats: false
        ) { [weak self] _ in
            self?.minimizeModalTouchBar()
        }
    }

    @objc private func systemTrayItemTapped() {
        presentModalTouchBar()
    }

    @objc private func minimizeButtonTapped() {
        minimizeModalTouchBar()
    }

    @objc private func closeButtonTapped() {
        dismissModalTouchBar()
    }
}

extension NSTouchBarItem.Identifier {
    static let droppySystemTray = NSTouchBarItem.Identifier("com.ranveer.droppy.touchbar.systemTray")
    static let droppyControlsHeader = NSTouchBarItem.Identifier("com.ranveer.droppy.touchbar.controlsHeader")
    static let droppyMedia = NSTouchBarItem.Identifier("com.ranveer.droppy.touchbar.media")
    static let droppyClipboard = NSTouchBarItem.Identifier("com.ranveer.droppy.touchbar.clipboard")
    static let droppyShelf = NSTouchBarItem.Identifier("com.ranveer.droppy.touchbar.shelf")
    static let droppyCodexProfile = NSTouchBarItem.Identifier("com.ranveer.droppy.touchbar.codexProfile")
    static let droppyStats = NSTouchBarItem.Identifier("com.ranveer.droppy.touchbar.stats")
    static let droppyTimer = NSTouchBarItem.Identifier("com.ranveer.droppy.touchbar.timer")
    static let droppyProfileStatus = NSTouchBarItem.Identifier("com.ranveer.droppy.touchbar.profileStatus")
    static let droppyMinimize = NSTouchBarItem.Identifier("com.ranveer.droppy.touchbar.minimize")
    static let droppyClose = NSTouchBarItem.Identifier("com.ranveer.droppy.touchbar.close")
}

private enum SystemModalTouchBarBridge {
    private static let addSystemTrayItemSelector = Selector(("addSystemTrayItem:"))
    private static let removeSystemTrayItemSelector = Selector(("removeSystemTrayItem:"))
    private static let presentSelector = Selector(("presentSystemModalTouchBar:systemTrayItemIdentifier:"))
    private static let dismissSelector = Selector(("dismissSystemModalTouchBar:"))
    private static let minimizeSelector = Selector(("minimizeSystemModalTouchBar:"))

    static var isSupported: Bool {
        NSTouchBarItem.responds(to: addSystemTrayItemSelector)
            && NSTouchBarItem.responds(to: removeSystemTrayItemSelector)
            && NSTouchBar.responds(to: presentSelector)
            && NSTouchBar.responds(to: dismissSelector)
            && NSTouchBar.responds(to: minimizeSelector)
    }

    static func addSystemTrayItem(_ item: NSTouchBarItem) -> Bool {
        guard NSTouchBarItem.responds(to: addSystemTrayItemSelector) else {
            return false
        }

        _ = NSTouchBarItem.perform(addSystemTrayItemSelector, with: item)
        return true
    }

    static func removeSystemTrayItem(_ item: NSTouchBarItem) {
        guard NSTouchBarItem.responds(to: removeSystemTrayItemSelector) else {
            return
        }

        _ = NSTouchBarItem.perform(removeSystemTrayItemSelector, with: item)
    }

    static func present(_ touchBar: NSTouchBar, systemTrayItemIdentifier: NSTouchBarItem.Identifier) {
        guard NSTouchBar.responds(to: presentSelector) else {
            return
        }

        _ = NSTouchBar.perform(presentSelector, with: touchBar, with: systemTrayItemIdentifier.rawValue)
    }

    static func dismiss(_ touchBar: NSTouchBar) {
        guard NSTouchBar.responds(to: dismissSelector) else {
            return
        }

        _ = NSTouchBar.perform(dismissSelector, with: touchBar)
    }

    static func minimize(_ touchBar: NSTouchBar) {
        guard NSTouchBar.responds(to: minimizeSelector) else {
            return
        }

        _ = NSTouchBar.perform(minimizeSelector, with: touchBar)
    }
}
