import AppKit

struct PermissionsManager {
    var onboardingMessage: String {
        """
        Droppy now lives in the menu bar. Phase 0 does not need special permissions, but later clipboard, drag monitoring, and media features may ask for local-only macOS permissions here.
        """
    }

    func openPrivacySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
            "x-apple.systempreferences:com.apple.preference.security"
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
