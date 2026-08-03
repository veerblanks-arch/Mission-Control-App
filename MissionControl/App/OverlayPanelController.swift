import AppKit
import SwiftUI

private final class DroppyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class OverlayPanelController: NSWindowController, NSWindowDelegate {
    private let model = OverlayPanelModel()
    private let fileFinder = FileFinderFeature.shared
    private let notes = NotesFeature.shared
    private let terminal = TerminalFeature.shared
    private let media = MediaFeature.shared
    private let codex = CodexFeature.shared
    private let unifiedSearch: UnifiedSearchFeature
    private weak var anchorButton: NSStatusBarButton?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var localKeyMonitor: Any?
    private var screenObserver: NSObjectProtocol?

    init() {
        let search = UnifiedSearchFeature(
            clipboard: .shared,
            shelf: .shared,
            files: fileFinder,
            notes: notes
        )
        unifiedSearch = search
        let initialSize = Settings.shared.panelSize
        let panel = DroppyPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Droppy"
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .utilityWindow
        panel.minSize = PanelGeometry.minimumSize
        panel.maxSize = PanelGeometry.maximumSize
        panel.contentViewController = NSHostingController(
            rootView: OverlayRootView(
                model: model,
                clipboardManager: .shared,
                shelf: .shared,
                fileFinder: fileFinder,
                notes: notes,
                terminal: terminal,
                media: media,
                codex: codex,
                unifiedSearch: search
            )
        )

        super.init(window: panel)

        panel.delegate = self
        ClipboardManagerFeature.shared.onRequestPanelClose = { [weak self] in
            self?.closePanel()
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard self?.window?.isVisible == true else {
                return
            }

            self?.positionPanel()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopDismissalMonitoring()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    func toggle(relativeTo statusButton: NSStatusBarButton) {
        if window?.isVisible == true {
            closePanel()
            return
        }

        show(relativeTo: statusButton)
    }

    func show(relativeTo statusButton: NSStatusBarButton) {
        anchorButton = statusButton
        showPanel()
    }

    func showClipboard(
        relativeTo statusButton: NSStatusBarButton,
        focusedItemID: UUID? = nil
    ) {
        model.showFeature(.clipboard)
        if let focusedItemID {
            ClipboardManagerFeature.shared.focus(focusedItemID)
        }
        show(relativeTo: statusButton)
    }

    func showCodex(
        relativeTo statusButton: NSStatusBarButton,
        threadID: String? = nil
    ) {
        model.showFeature(.codex)
        if let threadID {
            codex.openThread(id: threadID)
        }
        show(relativeTo: statusButton)
    }

    var onCaptureSnippet: ((SnippetCaptureMode) -> Void)? {
        get { model.onCaptureSnippet }
        set { model.onCaptureSnippet = newValue }
    }

    func dismissForCapture(completion: @escaping () -> Void) {
        closePanel()
        DispatchQueue.main.async(execute: completion)
    }

    func windowDidResize(_ notification: Notification) {
        guard let size = window?.frame.size else {
            return
        }

        Settings.shared.panelSize = size
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        positionPanel()
    }

    private func showPanel() {
        ClipboardManagerFeature.shared.setPasteTarget(
            NSWorkspace.shared.frontmostApplication
        )
        media.start()
        positionPanel()
        window?.makeKeyAndOrderFront(nil)
        startDismissalMonitoring()
    }

    private func closePanel() {
        stopDismissalMonitoring()
        media.stop()
        window?.orderOut(nil)
    }

    private func positionPanel() {
        guard
            let window,
            let anchorFrame = anchorFrame(),
            let screen = anchorButton?.window?.screen ?? NSScreen.main
        else {
            return
        }

        let frame = PanelGeometry.anchoredFrame(
            size: Settings.shared.panelSize,
            anchorFrame: anchorFrame,
            visibleScreenFrame: screen.visibleFrame
        )
        window.setFrame(frame, display: true)
    }

    private func anchorFrame() -> NSRect? {
        guard let anchorButton, let anchorWindow = anchorButton.window else {
            return nil
        }

        let frameInWindow = anchorButton.convert(anchorButton.bounds, to: nil)
        return anchorWindow.convertToScreen(frameInWindow)
    }

    private func startDismissalMonitoring() {
        stopDismissalMonitoring()

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.dismissIfOutsidePanel(at: NSEvent.mouseLocation)
        }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            self?.dismissIfOutsidePanel(at: NSEvent.mouseLocation)
            return event
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else {
                return event
            }

            if self?.model.isTerminalPresented == true {
                return event
            }
            self?.closePanel()
            return nil
        }
    }

    private func stopDismissalMonitoring() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }

        globalMouseMonitor = nil
        localMouseMonitor = nil
        localKeyMonitor = nil
    }

    private func dismissIfOutsidePanel(at screenPoint: NSPoint) {
        guard let window, window.isVisible else {
            return
        }

        if window.frame.contains(screenPoint) || anchorFrame()?.contains(screenPoint) == true {
            return
        }

        closePanel()
    }
}

final class OverlayPanelModel: ObservableObject {
    @Published var selectedFeature: OverlayFeature = .clipboard
    @Published private(set) var isTerminalPresented = false
    @Published private(set) var isSearchPresented = false
    var onCaptureSnippet: ((SnippetCaptureMode) -> Void)?

    func showFeature(_ feature: OverlayFeature) {
        selectedFeature = feature
        closeTemporarySurfaces()
    }

    func showTerminal() {
        isSearchPresented = false
        isTerminalPresented = true
    }

    func showSearch() {
        isTerminalPresented = false
        isSearchPresented = true
    }

    func closeTemporarySurfaces() {
        isTerminalPresented = false
        isSearchPresented = false
    }

    var displayedTitle: String {
        if isSearchPresented {
            return "Search"
        }
        if isTerminalPresented {
            return "Terminal"
        }
        return selectedFeature.title
    }

    var displayedSymbolName: String {
        if isSearchPresented {
            return "magnifyingglass"
        }
        if isTerminalPresented {
            return "terminal"
        }
        return selectedFeature.symbolName
    }

    var displayedSubtitle: String {
        if isSearchPresented {
            return "Across Droppy"
        }
        if isTerminalPresented {
            return "Retained shell sessions"
        }
        return selectedFeature.subtitle
    }
}
