import AppKit

final class SettingsWindowController: NSWindowController {
    private let permissionsManager: PermissionsManager

    init(permissionsManager: PermissionsManager) {
        self.permissionsManager = permissionsManager

        let viewController = OnboardingViewController(
            permissionsManager: permissionsManager
        )
        let window = NSWindow(contentViewController: viewController)
        window.title = "Silverdeck Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 520, height: 345))
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
        view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 345))

        let title = NSTextField(labelWithString: "Silverdeck")
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

        let separator = NSBox()
        separator.boxType = .separator

        let voiceTitle = NSTextField(labelWithString: "Conversational Voice")
        voiceTitle.font = .systemFont(ofSize: 15, weight: .semibold)

        let voiceBody = NSTextField(
            wrappingLabelWithString: "Voice conversations use the Codex account already signed in on this Mac. Silverdeck uses macOS Speech Recognition for microphone input, streams the Codex response, and reads it aloud with the macOS system voice. No OpenAI API key is required."
        )
        voiceBody.font = .systemFont(ofSize: 12)
        voiceBody.textColor = .secondaryLabelColor

        let voiceStatus = NSTextField(labelWithString: "Ready with Codex · Uses normal Codex plan limits")
        voiceStatus.font = .systemFont(ofSize: 11, weight: .medium)
        voiceStatus.textColor = .systemGreen

        let doneButton = NSButton(
            title: "Done",
            target: self,
            action: #selector(closeWindow)
        )
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"

        let stack = NSStackView(views: [
            title,
            body,
            settingsButton,
            separator,
            voiceTitle,
            voiceBody,
            voiceStatus,
            doneButton,
        ])
        stack.orientation = .vertical
        stack.spacing = 11
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -22),
            body.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            voiceBody.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @objc private func openPrivacySettings() {
        permissionsManager.openPrivacySettings()
    }

    @objc private func closeWindow() {
        view.window?.close()
    }
}
