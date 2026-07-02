import AppKit

struct PermissionsManager {
    var onboardingMessage: String {
        """
        Droppy adds a persistent icon to the Touch Bar Control Strip. Tap that icon to open Droppy's modal controls from any app. If the icon does not appear, open Keyboard Settings and make sure the Control Strip is shown.
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
