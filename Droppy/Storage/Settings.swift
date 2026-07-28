import Foundation

final class Settings {
    static let shared = Settings()

    private enum Keys {
        static let hasSeenOnboarding = "hasSeenOnboarding"
        static let panelWidth = "panelWidth"
        static let panelHeight = "panelHeight"
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

}
