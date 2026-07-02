import AppKit

final class MainTouchBarController: NSViewController, NSTouchBarDelegate {
    private enum Constants {
        static let touchBarIdentifier = NSTouchBar.CustomizationIdentifier("com.ranveer.droppy.touchbar.main")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 120))
    }

    override func makeTouchBar() -> NSTouchBar? {
        let touchBar = NSTouchBar()
        touchBar.delegate = self
        touchBar.customizationIdentifier = Constants.touchBarIdentifier
        touchBar.defaultItemIdentifiers = [
            .droppyVolumeBrightness,
            .droppyMedia,
            .droppyClipboard,
            .droppyShelf,
            .droppyCodexProfile,
            .droppyStats,
            .droppyTimer,
            .flexibleSpace,
            .droppyFallbackStatus
        ]
        touchBar.customizationAllowedItemIdentifiers = touchBar.defaultItemIdentifiers
        return touchBar
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        switch identifier {
        case .droppyVolumeBrightness:
            return iconButton(identifier: identifier, symbolName: "sun.max", label: "Display")
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
        case .droppyFallbackStatus:
            return statusItem(identifier: identifier)
        default:
            return nil
        }
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

    private func statusItem(identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: identifier)
        let label = NSTextField(labelWithString: "Droppy ready")
        label.alignment = .center
        label.font = .systemFont(ofSize: 13, weight: .medium)
        item.view = label
        item.customizationLabel = "Status"
        return item
    }
}

extension NSTouchBarItem.Identifier {
    static let droppyVolumeBrightness = NSTouchBarItem.Identifier("com.ranveer.droppy.touchbar.volumeBrightness")
    static let droppyMedia = NSTouchBarItem.Identifier("com.ranveer.droppy.touchbar.media")
    static let droppyClipboard = NSTouchBarItem.Identifier("com.ranveer.droppy.touchbar.clipboard")
    static let droppyShelf = NSTouchBarItem.Identifier("com.ranveer.droppy.touchbar.shelf")
    static let droppyCodexProfile = NSTouchBarItem.Identifier("com.ranveer.droppy.touchbar.codexProfile")
    static let droppyStats = NSTouchBarItem.Identifier("com.ranveer.droppy.touchbar.stats")
    static let droppyTimer = NSTouchBarItem.Identifier("com.ranveer.droppy.touchbar.timer")
    static let droppyFallbackStatus = NSTouchBarItem.Identifier("com.ranveer.droppy.touchbar.fallbackStatus")
}
