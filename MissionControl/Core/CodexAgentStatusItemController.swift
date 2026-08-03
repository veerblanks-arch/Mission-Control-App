import AppKit
import Combine

@MainActor
final class CodexAgentStatusItemController: NSObject {
    private let feature: CodexFeature
    private let onOpenThread: (String) -> Void
    private var statusItem: NSStatusItem?
    private var roleButtons: [CodexAgentRole: NSButton] = [:]
    private var cancellables = Set<AnyCancellable>()

    init(feature: CodexFeature, onOpenThread: @escaping (String) -> Void) {
        self.feature = feature
        self.onOpenThread = onOpenThread
        super.init()
    }

    func start() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: 96)
        guard let rootButton = item.button else { return }
        rootButton.image = nil
        rootButton.title = ""
        rootButton.action = nil

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fillEqually
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        rootButton.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: rootButton.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: rootButton.trailingAnchor),
            stack.topAnchor.constraint(equalTo: rootButton.topAnchor),
            stack.bottomAnchor.constraint(equalTo: rootButton.bottomAnchor),
        ])

        for (index, role) in CodexAgentRole.allCases.enumerated() {
            let button = NSButton()
            button.isBordered = false
            button.image = petImage(for: role)
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = role.title
            button.tag = index
            button.target = self
            button.action = #selector(roleClicked(_:))
            button.setAccessibilityLabel("\(role.title) Codex chats")
            stack.addArrangedSubview(button)
            roleButtons[role] = button
        }

        statusItem = item
        feature.$threads
            .combineLatest(feature.$managedThreadIDs)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.refreshState() }
            .store(in: &cancellables)
        refreshState()
    }

    func stop() {
        cancellables.removeAll()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        roleButtons.removeAll()
    }

    private func refreshState() {
        statusItem?.isVisible = true
        for role in CodexAgentRole.allCases {
            let count = feature.runningThreads(for: role).count
            roleButtons[role]?.contentTintColor = .white
            roleButtons[role]?.alphaValue = count > 0 ? 1 : 0.72
            roleButtons[role]?.toolTip = count == 1
                ? "\(role.title): 1 running chat"
                : "\(role.title): \(count) running chats"
        }
    }

    @objc private func roleClicked(_ sender: NSButton) {
        guard CodexAgentRole.allCases.indices.contains(sender.tag) else { return }
        let role = CodexAgentRole.allCases[sender.tag]
        let threads = feature.runningThreads(for: role)
        let menu = NSMenu(title: role.title)

        if threads.isEmpty {
            let item = NSMenuItem(title: "No running chats", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for thread in threads {
                let item = NSMenuItem(
                    title: "\(thread.projectName) — \(thread.title)",
                    action: #selector(openThread(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = thread.id
                menu.addItem(item)
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 3), in: sender)
    }

    @objc private func openThread(_ sender: NSMenuItem) {
        guard let threadID = sender.representedObject as? String else { return }
        onOpenThread(threadID)
    }

    private func petImage(for role: CodexAgentRole) -> NSImage? {
        let image: NSImage?
        if
            let url = Bundle.main.url(
                forResource: role.petTemplateAssetName,
                withExtension: "png"
            )
        {
            image = NSImage(contentsOf: url)
        } else {
            image = NSImage(
                systemSymbolName: role.symbolName,
                accessibilityDescription: role.title
            )
        }
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        return image
    }

}
