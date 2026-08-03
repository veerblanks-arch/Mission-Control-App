import AppKit
import ApplicationServices
import CoreGraphics

final class PermissionsManager {
    private var hasRequestedScreenCaptureAccess = false

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

    func requestScreenCaptureAccessIfNeeded() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }

        guard !hasRequestedScreenCaptureAccess else {
            return false
        }
        hasRequestedScreenCaptureAccess = true
        return CGRequestScreenCaptureAccess()
    }

    func openScreenRecordingSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
        openPrivacySettings()
    }
}

final class AccessibilityPasteAuthorizer {
    private let isTrusted: () -> Bool
    private let requestPermission: () -> Bool
    private var hasRequestedPermission = false

    init(
        isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        requestPermission: @escaping () -> Bool = {
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            return AXIsProcessTrustedWithOptions(
                [promptKey: true] as CFDictionary
            )
        }
    ) {
        self.isTrusted = isTrusted
        self.requestPermission = requestPermission
    }

    func canPostPasteEvent() -> Bool {
        if isTrusted() {
            return true
        }

        guard !hasRequestedPermission else {
            return false
        }
        hasRequestedPermission = true
        return requestPermission()
    }
}
