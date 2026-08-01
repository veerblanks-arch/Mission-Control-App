import AppKit
import Darwin

@MainActor
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
    private let shelf = ShelfFeature.shared
    private let terminal = TerminalFeature.shared
    private let media = MediaFeature.shared
    private let notes = NotesFeature.shared
    private lazy var dropZoneCoordinator = DropZoneCoordinator(shelf: shelf)
    private lazy var snippetCaptureCoordinator = SnippetCaptureCoordinator(
        clipboardManager: clipboardManager,
        permissionsManager: permissionsManager
    )
    private lazy var screenshotNotificationCoordinator = ScreenshotNotificationCoordinator {
        [weak self] itemID in
        self?.statusItemController.showClipboard(focusedItemID: itemID)
    }
    private var hasCompletedStartup = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        ApplicationMenu.install(in: NSApp)

        if !isRunningTests && terminateCurrentInstanceIfAnotherIsRunning() {
            return
        }

        completeStartup()
    }

    private func completeStartup() {
        guard !hasCompletedStartup else {
            return
        }

        hasCompletedStartup = true
        clipboardManager.onScreenshotCaptured = { [weak self] item, image in
            self?.screenshotNotificationCoordinator.show(item: item, image: image)
        }
        overlayPanelController.onCaptureSnippet = { [weak self] mode in
            guard let self else { return }
            self.screenshotNotificationCoordinator.dismiss()
            self.overlayPanelController.dismissForCapture { [weak self] in
                self?.snippetCaptureCoordinator.capture(mode)
            }
        }
        clipboardManager.start()
        statusItemController.start()
        dropZoneCoordinator.start()

#if DEBUG
        if CommandLine.arguments.contains("--show-panel") {
            DispatchQueue.main.async { [weak self] in
                self?.statusItemController.showClipboard()
            }
        }
        if CommandLine.arguments.contains("--show-drop-zone") {
            DispatchQueue.main.async { [weak self] in
                self?.dropZoneCoordinator.showForDebug()
            }
        }
        if CommandLine.arguments.contains("--show-snippet-editor") {
            DispatchQueue.main.async { [weak self] in
                self?.snippetCaptureCoordinator.showEditorForDebug()
            }
        }
#endif

        if !Settings.shared.hasSeenOnboarding {
            showSettings()
        }
    }

    private var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || environment["XCTestBundleInjectPath"] != nil
            || environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    private func terminateCurrentInstanceIfAnotherIsRunning() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return false
        }

        let currentProcessIdentifier = getpid()
        let otherInstances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.processIdentifier != currentProcessIdentifier }

        guard let existingInstance = otherInstances.first else {
            return false
        }

        existingInstance.activate()
        NSApp.terminate(nil)
        return true
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard notes.flushPendingSave() || confirmQuitWithoutSavingNotes() else {
            return .terminateCancel
        }
        guard terminal.hasRunningSessions else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = "Terminal sessions are still running"
        alert.informativeText =
            "Quitting Droppy will stop every shell and command running inside it."
        alert.addButton(withTitle: "Quit and Stop Sessions")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return .terminateCancel
        }
        terminal.stopAll { stopped in
            if !stopped {
                let alert = NSAlert()
                alert.messageText = "A terminal process could not be stopped"
                alert.informativeText =
                    "Droppy cancelled quitting so the process is not left behind."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
            NSApp.reply(toApplicationShouldTerminate: stopped)
        }
        return .terminateLater
    }

    private func confirmQuitWithoutSavingNotes() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Your notes could not be saved"
        alert.informativeText =
            "Cancel quitting to keep your unsaved notes open, then try again."
        alert.addButton(withTitle: "Cancel Quit")
        alert.addButton(withTitle: "Quit Without Saving")
        return alert.runModal() == .alertSecondButtonReturn
    }

    func applicationWillTerminate(_ notification: Notification) {
        notes.flushPendingSave()
        media.stop()
        terminal.stopAll()
        dropZoneCoordinator.stop()
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

enum ApplicationMenu {
    static func install(in application: NSApplication) {
        application.mainMenu = make()
    }

    static func make() -> NSMenu {
        let mainMenu = NSMenu()

        let applicationItem = NSMenuItem(title: "Droppy", action: nil, keyEquivalent: "")
        let applicationMenu = NSMenu(title: "Droppy")
        applicationMenu.addItem(
            withTitle: "Quit Droppy",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = makeEditMenu()
        mainMenu.addItem(editItem)

        return mainMenu
    }

    private static func makeEditMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(
            withTitle: "Undo",
            action: Selector(("undo:")),
            keyEquivalent: "z"
        )

        let redo = menu.addItem(
            withTitle: "Redo",
            action: Selector(("redo:")),
            keyEquivalent: "z"
        )
        redo.keyEquivalentModifierMask = [.command, .shift]

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Cut",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        )
        menu.addItem(
            withTitle: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        menu.addItem(
            withTitle: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        menu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        return menu
    }
}
