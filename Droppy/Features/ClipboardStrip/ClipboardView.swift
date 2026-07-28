import AppKit
import SwiftUI

struct ClipboardManagerView: View {
    @ObservedObject var manager: ClipboardManagerFeature
    @Binding var searchText: String

    @State private var filter: ClipboardFilter = .all
    @State private var isSelecting = false
    @State private var selection = Set<UUID>()
    @State private var isShowingPrivacyEditor = false
    @State private var isConfirmingClearEverything = false

    private var filteredItems: [ClipboardItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return manager.items.filter { item in
            filter.includes(item)
                && (query.isEmpty
                    || item.searchableContent.localizedCaseInsensitiveContains(query))
        }
    }

    private var pinnedItems: [ClipboardItem] {
        filteredItems.filter(\.isPinned)
    }

    private var historyItems: [ClipboardItem] {
        filteredItems.filter { !$0.isPinned }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            if isSelecting {
                selectionControls
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }

            Divider()

            statusArea

            if filteredItems.isEmpty {
                emptyState
            } else {
                itemList
            }
        }
        .sheet(isPresented: $isShowingPrivacyEditor) {
            ClipboardPrivacyEditor(manager: manager)
        }
        .alert("Clear all clipboard history?", isPresented: $isConfirmingClearEverything) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Everything", role: .destructive) {
                manager.clearEverything()
                selection.removeAll()
            }
        } message: {
            Text("This removes pinned and unpinned items. Original screenshot and file locations are untouched.")
        }
        .onChange(of: manager.items.map(\.id)) { _, validIDs in
            selection.formIntersection(validIDs)
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            searchField

            Menu {
                ForEach(ClipboardFilter.allCases) { option in
                    Button {
                        filter = option
                    } label: {
                        Label(option.title, systemImage: option.symbolName)
                    }
                }
            } label: {
                Image(systemName: filter.symbolName)
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .help("Filter: \(filter.title)")

            Button {
                manager.togglePaused()
            } label: {
                Image(systemName: manager.isPaused ? "play.fill" : "pause.fill")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help(manager.isPaused ? "Resume capture" : "Pause capture")

            Button {
                isShowingPrivacyEditor = true
            } label: {
                Image(systemName: "hand.raised.fill")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Private apps")

            Button {
                isSelecting.toggle()
                if !isSelecting {
                    selection.removeAll()
                }
            } label: {
                Image(systemName: isSelecting ? "checkmark.circle.fill" : "checkmark.circle")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isSelecting ? Color.accentColor : .secondary)
            .help(isSelecting ? "Finish selecting" : "Select items")

            Menu {
                Button("Clear History") {
                    manager.clearUnpinned()
                    selection.removeAll()
                }
                .disabled(manager.items.allSatisfy(\.isPinned))

                Button("Clear Everything", role: .destructive) {
                    isConfirmingClearEverything = true
                }
                .disabled(manager.items.isEmpty)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .help("More clipboard actions")
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search clipboard", text: $searchText)
                .textFieldStyle(.plain)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7))
    }

    private var selectionControls: some View {
        HStack(spacing: 8) {
            Button(selection.count == filteredItems.count ? "Deselect All" : "Select All") {
                if selection.count == filteredItems.count {
                    selection.removeAll()
                } else {
                    selection = Set(filteredItems.map(\.id))
                }
            }
            .disabled(filteredItems.isEmpty)

            Spacer()

            Button {
                manager.pin(selection)
            } label: {
                Image(systemName: "pin.fill")
            }
            .help("Pin selected")
            .disabled(selection.isEmpty)

            Button {
                manager.unpin(selection)
            } label: {
                Image(systemName: "pin.slash.fill")
            }
            .help("Unpin selected")
            .disabled(selection.isEmpty)

            Button(role: .destructive) {
                manager.delete(selection)
                selection.removeAll()
            } label: {
                Image(systemName: "trash")
            }
            .help("Delete selected")
            .disabled(selection.isEmpty)

            Text("\(selection.count) selected")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(minWidth: 68, alignment: .trailing)
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var statusArea: some View {
        if let storageError = manager.storageErrorMessage {
            Label(storageError, systemImage: "exclamationmark.lock.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.red)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.08))
        } else if manager.isPaused {
            Label("Capture paused. Clipboard changes and screenshots are being skipped.", systemImage: "pause.circle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.08))
        } else if manager.canUndoDeletion || manager.statusMessage != nil {
            HStack(spacing: 8) {
                Text(manager.canUndoDeletion ? "Clipboard item deleted" : manager.statusMessage ?? "")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)

                Spacer()

                if manager.canUndoDeletion {
                    Button("Undo") {
                        manager.undoDeletion()
                    }
                    .buttonStyle(.link)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.accentColor.opacity(0.08))
        }
    }

    private var itemList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8, pinnedViews: [.sectionHeaders]) {
                    if !pinnedItems.isEmpty {
                        section(title: "Pinned", items: pinnedItems)
                    }
                    if !historyItems.isEmpty {
                        section(title: "History", items: historyItems)
                    }
                }
                .padding(14)
            }
            .onChange(of: manager.requestedFocusItemID) { _, itemID in
                guard let itemID else { return }
                filter = .all
                searchText = ""
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(itemID, anchor: .center)
                    }
                }
            }
        }
    }

    private func section(title: String, items: [ClipboardItem]) -> some View {
        Section {
            ForEach(items) { item in
                ClipboardItemRow(
                    item: item,
                    manager: manager,
                    isSelecting: isSelecting,
                    isSelected: selection.contains(item.id),
                    onActivate: {
                        if isSelecting {
                            toggleSelection(item.id)
                        } else {
                            manager.activate(item)
                        }
                    }
                )
                .id(item.id)
            }
        } header: {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(items.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .background(.regularMaterial)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: searchText.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(emptyTitle)
                .font(.system(size: 15, weight: .semibold))
            Text(emptyMessage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var emptyTitle: String {
        if !searchText.isEmpty || filter != .all {
            return "No matching clipboard items"
        }
        return manager.isPaused ? "Clipboard capture is paused" : "Copy something to begin"
    }

    private var emptyMessage: String {
        if !searchText.isEmpty || filter != .all {
            return "Try another search or filter."
        }
        return "New clipboard entries and screenshots appear here."
    }

    private func toggleSelection(_ id: UUID) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }
}

private enum ClipboardFilter: String, CaseIterable, Identifiable {
    case all
    case text
    case images
    case files
    case screenshots
    case pinned

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .text: "Text"
        case .images: "Images"
        case .files: "Files"
        case .screenshots: "Screenshots"
        case .pinned: "Pinned"
        }
    }

    var symbolName: String {
        switch self {
        case .all: "line.3.horizontal.decrease.circle"
        case .text: "text.alignleft"
        case .images: "photo"
        case .files: "doc"
        case .screenshots: "camera.viewfinder"
        case .pinned: "pin.fill"
        }
    }

    func includes(_ item: ClipboardItem) -> Bool {
        switch self {
        case .all:
            true
        case .text:
            item.kind == .text
        case .images:
            item.kind == .image
        case .files:
            item.kind == .file
        case .screenshots:
            item.kind == .screenshot
        case .pinned:
            item.isPinned
        }
    }
}

private struct ClipboardItemRow: View {
    let item: ClipboardItem
    @ObservedObject var manager: ClipboardManagerFeature
    let isSelecting: Bool
    let isSelected: Bool
    let onActivate: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onActivate) {
                HStack(spacing: 11) {
                    if isSelecting {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    }

                    preview

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(item.title)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)

                            if item.isPinned {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.orange)
                            }

                            Spacer()

                            Text(item.formattedTime)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                        }

                        Text(item.subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Text(item.sourceAppName)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isSelecting ? "Select item" : "Paste into the previous app")

            if !isSelecting {
                ClipboardDragHandle(
                    content: { manager.dragContent(for: item) },
                    preview: dragPreview,
                    onSuccessfulDrop: { manager.completeSuccessfulDrag() }
                )
                .frame(width: 28, height: 36)
                .help("Drag item")
            }
        }
        .padding(9)
        .background(
            isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1)
            }
        }
        .contextMenu {
            Button(item.isPinned ? "Unpin" : "Pin") {
                if item.isPinned {
                    manager.unpin(Set([item.id]))
                } else {
                    manager.pin(Set([item.id]))
                }
            }
            Button("Delete", role: .destructive) {
                manager.delete(Set([item.id]))
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch item.kind {
        case .text:
            previewSymbol("text.alignleft", color: .blue)
        case .file:
            if let fileURL = manager.payload(for: item)?.fileReferences.first?.resolvedURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: fileURL.path))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)
            } else {
                previewSymbol("doc", color: .green)
            }
        case .image:
            imagePreview(fallback: "photo", color: .purple)
        case .screenshot:
            imagePreview(fallback: "camera.viewfinder", color: .orange)
        }
    }

    private func previewSymbol(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 40, height: 40)
            .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder
    private func imagePreview(fallback: String, color: Color) -> some View {
        if let image = manager.image(for: item) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 7))
        } else {
            previewSymbol(fallback, color: color)
        }
    }

    private var dragPreview: ClipboardDragPreview {
        switch item.kind {
        case .text:
            ClipboardDragPreview(label: "text")
        case .file:
            ClipboardDragPreview(label: "file")
        case .image:
            ClipboardDragPreview(label: "image")
        case .screenshot:
            ClipboardDragPreview(label: "screenshot")
        }
    }
}

private struct ClipboardDragHandle: NSViewRepresentable {
    let content: () -> ClipboardDragContent
    let preview: ClipboardDragPreview
    let onSuccessfulDrop: () -> Void

    func makeNSView(context: Context) -> ClipboardDragSourceView {
        ClipboardDragSourceView()
    }

    func updateNSView(_ view: ClipboardDragSourceView, context: Context) {
        view.content = content
        view.preview = preview
        view.onSuccessfulDrop = onSuccessfulDrop
    }
}

private struct ClipboardDragPreview {
    let label: String

    var image: NSImage {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        let textSize = (label as NSString).size(withAttributes: attributes)
        let imageSize = NSSize(
            width: ceil(textSize.width) + 18,
            height: 24
        )

        return NSImage(size: imageSize, flipped: false) { canvas in
            let badgeRect = canvas.insetBy(dx: 0.5, dy: 0.5)
            let badgePath = NSBezierPath(
                roundedRect: badgeRect,
                xRadius: 6,
                yRadius: 6
            )

            NSColor.controlBackgroundColor.withAlphaComponent(0.96).setFill()
            badgePath.fill()
            NSColor.separatorColor.withAlphaComponent(0.65).setStroke()
            badgePath.lineWidth = 1
            badgePath.stroke()

            let textRect = NSRect(
                x: (canvas.width - textSize.width) / 2,
                y: (canvas.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            (label as NSString).draw(
                in: textRect,
                withAttributes: attributes
            )
            return true
        }
    }
}

private final class ClipboardDragSourceView: NSView, NSDraggingSource {
    var content: (() -> ClipboardDragContent)?
    var preview: ClipboardDragPreview?
    var onSuccessfulDrop: (() -> Void)?
    private var didBeginDrag = false
    private var activeContent: ClipboardDragContent?
    private var recentlyCompletedContents: [ClipboardDragContent] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.image = NSImage(
            systemSymbolName: "line.3.horizontal",
            accessibilityDescription: "Drag item"
        )
        imageView.contentTintColor = .secondaryLabelColor
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 15),
            imageView.heightAnchor.constraint(equalToConstant: 15),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        didBeginDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard
            !didBeginDrag,
            let content,
            let preview
        else {
            return
        }
        let dragContent = content()
        let pasteboardWriters = dragContent.writers
        guard !pasteboardWriters.isEmpty else {
            return
        }
        didBeginDrag = true
        activeContent = dragContent

        let previewImage = preview.image
        let previewSize = previewImage.size
        let previewFrame = NSRect(
            x: bounds.midX - previewSize.width / 2,
            y: bounds.midY - previewSize.height / 2,
            width: previewSize.width,
            height: previewSize.height
        )
        let draggingItems = pasteboardWriters.enumerated().map { index, writer -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: writer)
            let offset = CGFloat(min(index, 3)) * 3
            item.setDraggingFrame(
                previewFrame.offsetBy(dx: offset, dy: -offset),
                contents: previewImage
            )
            return item
        }
        let session = beginDraggingSession(
            with: draggingItems,
            event: event,
            source: self
        )
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = draggingItems.count > 1 ? .stack : .none
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        if !operation.isEmpty, let activeContent {
            recentlyCompletedContents.append(activeContent)
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self, weak activeContent] in
                guard let activeContent else {
                    return
                }
                self?.recentlyCompletedContents.removeAll { $0 === activeContent }
            }
        }
        activeContent = nil
        if !operation.isEmpty {
            onSuccessfulDrop?()
        }
    }
}

private struct ClipboardPrivacyEditor: View {
    @ObservedObject var manager: ClipboardManagerFeature
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Private Apps")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Clipboard changes from these apps are ignored.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .padding(16)

            Divider()

            List {
                ForEach(manager.excludedApps) { app in
                    HStack {
                        Image(systemName: "app.badge.checkmark")
                            .foregroundStyle(.secondary)
                        Text(app.displayName)
                        Spacer()
                        Button {
                            manager.removeExcludedApplication(app)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove exclusion")
                    }
                }
            }

            Divider()

            HStack {
                Button("Exclude Previous App") {
                    manager.excludePasteTarget()
                }

                Spacer()

                Button {
                    chooseApplication()
                } label: {
                    Label("Add Application", systemImage: "plus")
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 430, height: 360)
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "Choose a private application"
        panel.prompt = "Exclude"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        manager.addExcludedApplication(url: url)
    }
}
