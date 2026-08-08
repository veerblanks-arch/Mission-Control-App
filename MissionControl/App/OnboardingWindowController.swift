import AppKit

final class SettingsWindowController: NSWindowController {
    private let permissionsManager: PermissionsManager

    init(permissionsManager: PermissionsManager) {
        self.permissionsManager = permissionsManager

        let viewController = OnboardingViewController(
            permissionsManager: permissionsManager
        )
        let window = NSWindow(contentViewController: viewController)
        window.title = "Mission Control Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 520, height: 300))
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class OnboardingViewController: NSViewController {
    private let permissionsManager: PermissionsManager

    init(permissionsManager: PermissionsManager) {
        self.permissionsManager = permissionsManager
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 300))

        let title = NSTextField(labelWithString: "Mission Control")
        title.font = .systemFont(ofSize: 22, weight: .semibold)

        let body = NSTextField(wrappingLabelWithString: permissionsManager.onboardingMessage)
        body.font = .systemFont(ofSize: 13)
        body.textColor = .secondaryLabelColor

        let settingsButton = NSButton(
            title: "Open Privacy Settings",
            target: self,
            action: #selector(openPrivacySettings)
        )
        settingsButton.bezelStyle = .rounded

        let previewButton = NSButton(
            title: "Done",
            target: self,
            action: #selector(closeWindow)
        )
        previewButton.bezelStyle = .rounded
        previewButton.keyEquivalent = "\r"

        let buttonRow = NSStackView(views: [settingsButton, previewButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 12
        buttonRow.alignment = .centerY

        let stack = NSStackView(views: [title, body, buttonRow])
        stack.orientation = .vertical
        stack.spacing = 18
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            body.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    @objc private func openPrivacySettings() {
        permissionsManager.openPrivacySettings()
    }

    @objc private func closeWindow() {
        view.window?.close()
    }
}
