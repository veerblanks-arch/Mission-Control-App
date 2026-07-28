import AppKit
import SwiftUI

final class DropZoneCoordinator {
    private enum State {
        case idle
        case armed(screen: NSScreen, generation: Int)
        case ready(screen: NSScreen, generation: Int)
        case success
    }

    private let shelf: ShelfFeature
    private let panelController = DropZonePanelController()
    private var state: State = .idle
    private var generation = 0
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var hoverWorkItem: DispatchWorkItem?
    private var dismissWorkItem: DispatchWorkItem?

    init(shelf: ShelfFeature = .shared) {
        self.shelf = shelf
        panelController.onDrop = { [weak self] urls in
            self?.performDrop(urls) ?? false
        }
    }

    func start() {
        guard globalMonitor == nil, localMonitor == nil else {
            return
        }

        let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }

        globalMonitor = nil
        localMonitor = nil
        reset()
    }

#if DEBUG
    func showForDebug() {
        let screen = screen(containing: NSEvent.mouseLocation) ?? NSScreen.main
        guard let screen else {
            return
        }

        generation += 1
        state = .ready(screen: screen, generation: generation)
        panelController.arm(on: screen)
        panelController.reveal()
    }
#endif

    private func handle(_ event: NSEvent) {
        if event.type == .leftMouseUp {
            if case .success = state {
                return
            }
            reset()
            return
        }

        guard dragPasteboardContainsFileURLs() else {
            reset()
            return
        }

        let point = NSEvent.mouseLocation
        guard let currentScreen = screen(containing: point) else {
            reset()
            return
        }

        let activationFrame = DropZoneGeometry.activationFrame(for: currentScreen.frame)
        let isInsidePanel = panelController.frame.contains(point)
        guard activationFrame.contains(point) || isInsidePanel else {
            reset()
            return
        }

        switch state {
        case .idle:
            arm(on: currentScreen)
        case let .armed(screen, _), let .ready(screen, _):
            if screen != currentScreen {
                arm(on: currentScreen)
            }
        case .success:
            break
        }
    }

    private func arm(on screen: NSScreen) {
        generation += 1
        let currentGeneration = generation
        state = .armed(screen: screen, generation: currentGeneration)
        panelController.arm(on: screen)

        hoverWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self, weak screen] in
            guard let self, let screen else {
                return
            }
            self.revealIfStillEligible(on: screen, generation: currentGeneration)
        }
        hoverWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: workItem)
    }

    private func revealIfStillEligible(on screen: NSScreen, generation: Int) {
        guard
            case let .armed(armedScreen, armedGeneration) = state,
            armedScreen == screen,
            armedGeneration == generation,
            NSEvent.pressedMouseButtons & 1 == 1,
            dragPasteboardContainsFileURLs()
        else {
            reset()
            return
        }

        let point = NSEvent.mouseLocation
        let activationFrame = DropZoneGeometry.activationFrame(for: screen.frame)
        guard activationFrame.contains(point) || panelController.frame.contains(point) else {
            reset()
            return
        }

        state = .ready(screen: screen, generation: generation)
        panelController.reveal()
    }

    private func performDrop(_ urls: [URL]) -> Bool {
        guard case .ready = state else {
            return false
        }

        let addedCount = shelf.add(urls)
        guard addedCount > 0 else {
            panelController.showFailure()
            scheduleDismissal(after: 2)
            return false
        }

        hoverWorkItem?.cancel()
        state = .success
        panelController.showSuccess(count: addedCount)
        scheduleDismissal(after: 2)
        return true
    }

    private func scheduleDismissal(after delay: TimeInterval) {
        dismissWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.reset()
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func reset() {
        generation += 1
        hoverWorkItem?.cancel()
        dismissWorkItem?.cancel()
        hoverWorkItem = nil
        dismissWorkItem = nil
        state = .idle
        panelController.hide()
    }

    private func dragPasteboardContainsFileURLs() -> Bool {
        NSPasteboard(name: .drag).availableType(from: [.fileURL]) != nil
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }
}

private final class DropZonePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class DropZonePanelController {
    var onDrop: (([URL]) -> Bool)?

    private let model = DropZoneModel()
    private let panel: DropZonePanel
    private let receivingView: DropZoneReceivingView

    init() {
        panel = DropZonePanel(
            contentRect: NSRect(origin: .zero, size: DropZoneGeometry.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        receivingView = DropZoneReceivingView(model: model)

        panel.title = "Drop to Shelf"
        panel.level = .popUpMenu
        if #available(macOS 15.0, *) {
            panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .transient, .ignoresCycle]
        } else {
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        }
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.contentView = receivingView

        receivingView.canAcceptDrop = { [weak model] in
            model?.phase.acceptsDrop == true
        }
        receivingView.onTargetChange = { [weak model] isTargeted in
            guard let model, model.phase.acceptsDrop else {
                return
            }
            model.phase = isTargeted ? .targeted : .ready
        }
        receivingView.onDrop = { [weak self] urls in
            self?.onDrop?(urls) ?? false
        }
    }

    var frame: NSRect {
        panel.frame
    }

    func arm(on screen: NSScreen) {
        model.phase = .armed
        panel.alphaValue = 0.01
        panel.setFrame(DropZoneGeometry.panelFrame(for: screen.frame), display: true)
        panel.orderFrontRegardless()
    }

    func reveal() {
        model.phase = .ready
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel.animator().alphaValue = 1
        }
    }

    func showSuccess(count: Int) {
        model.phase = .success(count: count)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func showFailure() {
        model.phase = .failure
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
        panel.alphaValue = 0.01
        model.phase = .armed
    }
}

private final class DropZoneReceivingView: NSView {
    var canAcceptDrop: (() -> Bool)?
    var onTargetChange: ((Bool) -> Void)?
    var onDrop: (([URL]) -> Bool)?

    private let hostingView: NSHostingView<DropZoneView>

    init(model: DropZoneModel) {
        hostingView = NSHostingView(rootView: DropZoneView(model: model))
        super.init(frame: NSRect(origin: .zero, size: DropZoneGeometry.panelSize))

        registerForDraggedTypes([.fileURL])
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.availableType(from: [.fileURL]) != nil else {
            return []
        }

        onTargetChange?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.availableType(from: [.fileURL]) == nil ? [] : .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onTargetChange?(false)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        canAcceptDrop?() == true
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard canAcceptDrop?() == true else {
            return false
        }

        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        guard !urls.isEmpty else {
            return false
        }

        return onDrop?(urls) ?? false
    }
}

private final class DropZoneModel: ObservableObject {
    @Published var phase: DropZonePhase = .armed
}

private enum DropZonePhase: Equatable {
    case armed
    case ready
    case targeted
    case success(count: Int)
    case failure

    var acceptsDrop: Bool {
        self == .ready || self == .targeted
    }
}

private struct DropZoneView: View {
    @ObservedObject var model: DropZoneModel

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbolName)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(symbolColor)
                .frame(width: 46, height: 46)
                .background(symbolColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: DropZoneGeometry.panelSize.width, height: DropZoneGeometry.panelSize.height)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(borderColor, lineWidth: model.phase == .targeted ? 2 : 1)
        }
    }

    private var title: String {
        switch model.phase {
        case .armed, .ready:
            return "Drop to Shelf"
        case .targeted:
            return "Release to add"
        case let .success(count):
            return count == 1 ? "Added to Shelf" : "Added \(count) items"
        case .failure:
            return "Could not add items"
        }
    }

    private var subtitle: String {
        switch model.phase {
        case .armed, .ready, .targeted:
            return "Files and folders stay in their original location."
        case .success:
            return "Saved as references. Originals were not moved."
        case .failure:
            return "The original files were left untouched."
        }
    }

    private var symbolName: String {
        switch model.phase {
        case .armed, .ready, .targeted:
            return "tray.and.arrow.down"
        case .success:
            return "checkmark"
        case .failure:
            return "exclamationmark"
        }
    }

    private var symbolColor: Color {
        switch model.phase {
        case .armed, .ready:
            return .secondary
        case .targeted:
            return .blue
        case .success:
            return .green
        case .failure:
            return .red
        }
    }

    private var borderColor: Color {
        switch model.phase {
        case .targeted:
            return .blue.opacity(0.8)
        case .success:
            return .green.opacity(0.7)
        case .failure:
            return .red.opacity(0.7)
        case .armed, .ready:
            return .white.opacity(0.18)
        }
    }
}
