import AppKit

struct PermissionsManager {
    var onboardingMessage: String {
        """
        Droppy needs macOS to show App Controls in the Touch Bar. Open Keyboard Settings, find the Touch Bar behavior setting, and choose App Controls. If that setting is disabled, the app can still run from the menu bar, but the Touch Bar row may not appear.
        """
    }

    func openKeyboardSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.keyboard"
        ]

        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }

        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/System/Applications/System Settings.app"),
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

}
