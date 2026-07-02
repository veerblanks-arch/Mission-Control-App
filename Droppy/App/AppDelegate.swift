import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let touchBarController = MainTouchBarController()
    private lazy var onboardingWindowController = OnboardingWindowController(
        permissionsManager: permissionsManager,
        onShowTouchBar: { [weak self] in
            self?.showTouchBarHost()
        }
    )
    private let permissionsManager = PermissionsManager()
    private var touchBarHostWindowController: TouchBarHostWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        TouchBarProfileManager.shared.start()
        touchBarController.start()

        if !Settings.shared.hasSeenOnboarding {
            showSettings()
        } else {
            showTouchBarHost()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        touchBarController.stop()
        TouchBarProfileManager.shared.stop()
    }

    private func configureStatusItem() {
        statusItem.button?.image = NSImage(
            systemSymbolName: "rectangle.and.hand.point.up.left",
            accessibilityDescription: "Droppy"
        )
        statusItem.button?.imagePosition = .imageOnly

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Settings", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Show Touch Bar Row", action: #selector(showTouchBarRow), keyEquivalent: "t"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Droppy", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    @objc private func showSettings() {
        Settings.shared.hasSeenOnboarding = true
        configureStatusItem()
        onboardingWindowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showTouchBarRow() {
        showTouchBarHost()
    }

    private func showTouchBarHost() {
        if touchBarHostWindowController == nil {
            touchBarHostWindowController = TouchBarHostWindowController(contentController: touchBarController)
        }

        touchBarHostWindowController?.showWindow(nil)
        touchBarHostWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
