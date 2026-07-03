import AppKit
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let touchBarController = MainTouchBarController()
    private lazy var onboardingWindowController = OnboardingWindowController(
        permissionsManager: permissionsManager,
        onShowTouchBar: { [weak self] in
            self?.showDroppyTouchBar()
        }
    )
    private let permissionsManager = PermissionsManager()
    private var hasCompletedStartup = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if terminateOtherRunningInstancesIfNeeded() {
            return
        }

        completeStartup()
    }

    private func completeStartup() {
        guard !hasCompletedStartup else {
            return
        }

        hasCompletedStartup = true
        configureStatusItem()
        TouchBarProfileManager.shared.start()
        touchBarController.start()

        if !Settings.shared.hasSeenOnboarding {
            showSettings()
        }
    }

    private func terminateOtherRunningInstancesIfNeeded() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return false
        }

        let currentProcessIdentifier = getpid()
        let otherInstances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.processIdentifier != currentProcessIdentifier }

        guard !otherInstances.isEmpty else {
            return false
        }

        otherInstances.forEach { app in
            if !app.terminate() {
                app.forceTerminate()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            let remainingInstances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .filter { $0.processIdentifier != currentProcessIdentifier }

            remainingInstances.forEach { $0.forceTerminate() }
            self?.completeStartup()
        }

        return true
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
        menu.addItem(NSMenuItem(title: "Show Droppy Touch Bar", action: #selector(showDroppyTouchBar), keyEquivalent: "t"))
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

    @objc private func showDroppyTouchBar() {
        touchBarController.presentModalTouchBar()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
