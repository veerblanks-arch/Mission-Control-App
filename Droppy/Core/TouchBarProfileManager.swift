import AppKit

final class TouchBarProfileManager {
    static let shared = TouchBarProfileManager()

    private(set) var activeProfile: TouchBarProfile = .default
    private var observer: NSObjectProtocol?

    private init() {}

    func start() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.frontmostApplicationDidChange(notification)
        }
    }

    func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
    }

    private func frontmostApplicationDidChange(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            activeProfile = .default
            return
        }

        activeProfile = TouchBarProfile.profile(for: app)
    }
}

enum TouchBarProfile: Equatable {
    case codex
    case `default`

    static func profile(for application: NSRunningApplication) -> TouchBarProfile {
        let appName = application.localizedName?.lowercased() ?? ""
        let bundleIdentifier = application.bundleIdentifier?.lowercased() ?? ""

        if appName.contains("codex") || bundleIdentifier.contains("codex") {
            return .codex
        }

        return .default
    }
}
