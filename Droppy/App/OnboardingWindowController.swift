import AppKit

final class OnboardingWindowController: NSWindowController {
    private let permissionsManager: PermissionsManager
    private let onShowTouchBar: () -> Void

    init(permissionsManager: PermissionsManager, onShowTouchBar: @escaping () -> Void) {
        self.permissionsManager = permissionsManager
        self.onShowTouchBar = onShowTouchBar

        let viewController = OnboardingViewController(
            permissionsManager: permissionsManager,
            onShowTouchBar: onShowTouchBar
        )
        let window = NSWindow(contentViewController: viewController)
        window.title = "Droppy Setup"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 520, height: 300))
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
    private let onShowTouchBar: () -> Void

    init(permissionsManager: PermissionsManager, onShowTouchBar: @escaping () -> Void) {
        self.permissionsManager = permissionsManager
        self.onShowTouchBar = onShowTouchBar
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 300))

        let title = NSTextField(labelWithString: "Enable Touch Bar app controls")
        title.font = .systemFont(ofSize: 22, weight: .semibold)

        let body = NSTextField(wrappingLabelWithString: permissionsManager.onboardingMessage)
        body.font = .systemFont(ofSize: 13)
        body.textColor = .secondaryLabelColor

        let settingsButton = NSButton(
            title: "Open Keyboard Settings",
            target: self,
            action: #selector(openKeyboardSettings)
        )
        settingsButton.bezelStyle = .rounded

        let previewButton = NSButton(
            title: "Show Touch Bar Row",
            target: self,
            action: #selector(showTouchBarRow)
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

    @objc private func openKeyboardSettings() {
        permissionsManager.openKeyboardSettings()
    }

    @objc private func showTouchBarRow() {
        onShowTouchBar()
    }
}
