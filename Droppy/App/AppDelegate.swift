import AppKit
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var overlayPanelController = OverlayPanelController()
    private lazy var statusItemController = StatusItemController(
        overlayPanelController: overlayPanelController,
        onShowSettings: { [weak self] in
            self?.showSettings()
        },
        onQuit: { [weak self] in
            self?.quit()
        }
    )
    private lazy var settingsWindowController = SettingsWindowController(
        permissionsManager: permissionsManager
    )
    private let permissionsManager = PermissionsManager()
    private let clipboardManager = ClipboardManagerFeature.shared
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
        clipboardManager.start()
        statusItemController.start()

#if DEBUG
        if CommandLine.arguments.contains("--show-panel") {
            DispatchQueue.main.async { [weak self] in
                self?.statusItemController.showClipboard()
            }
        }
#endif

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
        clipboardManager.stop()
        statusItemController.stop()
    }

    @objc private func showSettings() {
        Settings.shared.hasSeenOnboarding = true
        settingsWindowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
