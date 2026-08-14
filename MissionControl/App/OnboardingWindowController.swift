import AppKit

final class SettingsWindowController: NSWindowController {
    private let permissionsManager: PermissionsManager

    init(permissionsManager: PermissionsManager) {
        self.permissionsManager = permissionsManager

        let viewController = OnboardingViewController(
            permissionsManager: permissionsManager,
            keyStore: RealtimeAPIKeyStore()
        )
        let window = NSWindow(contentViewController: viewController)
        window.title = "Silverdeck Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 520, height: 430))
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
    private let keyStore: RealtimeAPIKeyStore
    private let apiKeyField = NSSecureTextField()
    private let apiKeyStatus = NSTextField(wrappingLabelWithString: "")

    init(
        permissionsManager: PermissionsManager,
        keyStore: RealtimeAPIKeyStore
    ) {
        self.permissionsManager = permissionsManager
        self.keyStore = keyStore
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 430))

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
            wrappingLabelWithString: "Add an OpenAI API key to use low-latency Realtime voice. The key stays in this Mac’s Keychain; API usage is billed to that OpenAI account."
        )
        voiceBody.font = .systemFont(ofSize: 12)
        voiceBody.textColor = .secondaryLabelColor

        apiKeyField.placeholderString = "OpenAI API key"
        apiKeyField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)

        let saveKeyButton = NSButton(
            title: "Save API Key",
            target: self,
            action: #selector(saveAPIKey)
        )
        saveKeyButton.bezelStyle = .rounded

        let removeKeyButton = NSButton(
            title: "Remove Key",
            target: self,
            action: #selector(removeAPIKey)
        )
        removeKeyButton.bezelStyle = .rounded

        apiKeyStatus.font = .systemFont(ofSize: 11)
        apiKeyStatus.textColor = .secondaryLabelColor

        let keyButtonRow = NSStackView(views: [saveKeyButton, removeKeyButton])
        keyButtonRow.orientation = .horizontal
        keyButtonRow.spacing = 10
        keyButtonRow.alignment = .centerY

        let previewButton = NSButton(
            title: "Done",
            target: self,
            action: #selector(closeWindow)
        )
        previewButton.bezelStyle = .rounded
        previewButton.keyEquivalent = "\r"

        let stack = NSStackView(views: [
            title,
            body,
            settingsButton,
            separator,
            voiceTitle,
            voiceBody,
            apiKeyField,
            keyButtonRow,
            apiKeyStatus,
            previewButton,
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
            apiKeyField.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        refreshAPIKeyStatus()
    }

    @objc private func openPrivacySettings() {
        permissionsManager.openPrivacySettings()
    }

    @objc private func closeWindow() {
        view.window?.close()
    }

    @objc private func saveAPIKey() {
        do {
            try keyStore.save(apiKeyField.stringValue)
            apiKeyField.stringValue = ""
            apiKeyStatus.textColor = .systemGreen
            apiKeyStatus.stringValue = "API key saved securely in Keychain."
        } catch {
            apiKeyStatus.textColor = .systemOrange
            apiKeyStatus.stringValue = error.localizedDescription
        }
    }

    @objc private func removeAPIKey() {
        do {
            try keyStore.delete()
            apiKeyField.stringValue = ""
            apiKeyStatus.textColor = .secondaryLabelColor
            apiKeyStatus.stringValue = "No API key is saved."
        } catch {
            apiKeyStatus.textColor = .systemOrange
            apiKeyStatus.stringValue = error.localizedDescription
        }
    }

    private func refreshAPIKeyStatus() {
        do {
            apiKeyStatus.stringValue = try keyStore.load() == nil
                ? "No API key is saved."
                : "An API key is saved in Keychain."
            apiKeyStatus.textColor = .secondaryLabelColor
        } catch {
            apiKeyStatus.stringValue = error.localizedDescription
            apiKeyStatus.textColor = .systemOrange
        }
    }
}
