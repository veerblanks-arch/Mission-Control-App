import Foundation

final class Settings {
    static let shared = Settings()

    private enum Keys {
        static let hasSeenOnboarding = "hasSeenOnboarding"
        static let panelWidth = "panelWidth"
        static let panelHeight = "panelHeight"
        static let clipboardCapturePaused = "clipboardCapturePaused"
        static let excludedClipboardApps = "excludedClipboardApps"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hasSeenOnboarding: Bool {
        get { defaults.bool(forKey: Keys.hasSeenOnboarding) }
        set { defaults.set(newValue, forKey: Keys.hasSeenOnboarding) }
    }

    var panelSize: NSSize {
        get {
            let width = defaults.double(forKey: Keys.panelWidth)
            let height = defaults.double(forKey: Keys.panelHeight)
            guard width > 0, height > 0 else {
                return PanelGeometry.defaultSize
            }

            return PanelGeometry.clampedSize(NSSize(width: width, height: height))
        }
        set {
            let size = PanelGeometry.clampedSize(newValue)
            defaults.set(size.width, forKey: Keys.panelWidth)
            defaults.set(size.height, forKey: Keys.panelHeight)
        }
    }

    var clipboardCapturePaused: Bool {
        get { defaults.bool(forKey: Keys.clipboardCapturePaused) }
        set { defaults.set(newValue, forKey: Keys.clipboardCapturePaused) }
    }

    var excludedClipboardApps: [ExcludedClipboardApp] {
        get {
            if
                let data = defaults.data(forKey: Keys.excludedClipboardApps),
                let apps = try? JSONDecoder().decode([ExcludedClipboardApp].self, from: data)
            {
                return apps
            }
            return Self.defaultExcludedClipboardApps
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else {
                return
            }
            defaults.set(data, forKey: Keys.excludedClipboardApps)
        }
    }

    private static let defaultExcludedClipboardApps = [
        ExcludedClipboardApp(
            bundleIdentifier: "com.1password.1password",
            displayName: "1Password"
        ),
        ExcludedClipboardApp(
            bundleIdentifier: "com.agilebits.onepassword7",
            displayName: "1Password 7"
        ),
        ExcludedClipboardApp(
            bundleIdentifier: "com.bitwarden.desktop",
            displayName: "Bitwarden"
        ),
        ExcludedClipboardApp(
            bundleIdentifier: "org.keepassxc.keepassxc",
            displayName: "KeePassXC"
        ),
        ExcludedClipboardApp(
            bundleIdentifier: "com.lastpass.LastPass",
            displayName: "LastPass"
        ),
        ExcludedClipboardApp(
            bundleIdentifier: "me.proton.pass",
            displayName: "Proton Pass"
        ),
    ]

}
