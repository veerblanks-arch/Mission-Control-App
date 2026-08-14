import AppKit
import Combine
import UniformTypeIdentifiers

enum ClipboardDragExportStore {
    static let retentionDuration: TimeInterval = 24 * 60 * 60

    static var defaultRootURL: URL {
        let cachesURL = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return cachesURL
            .appendingPathComponent(
                Bundle.main.bundleIdentifier ?? "com.ranveer.droppy",
                isDirectory: true
            )
            .appendingPathComponent("DragExports", isDirectory: true)
    }

    static func makeExport(
        data: Data,
        fileName: String,
        rootURL: URL = defaultRootURL,
        now: Date = Date()
    ) throws -> (directoryURL: URL, fileURL: URL) {
        removeExpired(in: rootURL, now: now)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )

        let directoryURL = rootURL
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.creationDate: now, .modificationDate: now],
            ofItemAtPath: directoryURL.path
        )

        let fileURL = directoryURL.appendingPathComponent(fileName)
        do {
            try data.write(to: fileURL, options: .atomic)
            scheduleRemoval(of: directoryURL)
            return (directoryURL, fileURL)
        } catch {
            try? FileManager.default.removeItem(at: directoryURL)
            throw error
        }
    }

    static func removeExpired(
        in rootURL: URL = defaultRootURL,
        now: Date = Date()
    ) {
        guard let exports = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .creationDateKey,
                .contentModificationDateKey,
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for exportURL in exports {
            guard
                let values = try? exportURL.resourceValues(
                    forKeys: [
                        .isDirectoryKey,
                        .creationDateKey,
                        .contentModificationDateKey,
                    ]
                ),
                values.isDirectory == true,
                let createdAt = values.creationDate ?? values.contentModificationDate,
                now.timeIntervalSince(createdAt) >= retentionDuration
            else {
                continue
            }
            try? FileManager.default.removeItem(at: exportURL)
        }
    }

    private static func scheduleRemoval(of directoryURL: URL) {
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + retentionDuration
        ) {
            try? FileManager.default.removeItem(at: directoryURL)
        }
    }
}

@MainActor
final class ClipboardManagerFeature: ObservableObject {
    static let shared = ClipboardManagerFeature()
    static let phase = 3

    @Published private(set) var items: [ClipboardItem] = []
    @Published private(set) var isPaused: Bool
    @Published private(set) var excludedApps: [ExcludedClipboardApp]
    @Published private(set) var canUndoDeletion = false
    @Published private(set) var storageErrorMessage: String?
    @Published private(set) var statusMessage: String?
    @Published var requestedFocusItemID: UUID?

    var onRequestPanelClose: (() -> Void)?
    var onScreenshotCaptured: ((ClipboardItem, NSImage) -> Void)?

    private var repository: ClipboardRepository?
    private let settings: Settings
    private let retentionPolicy: ClipboardRetentionPolicy
    private let screenshotMonitor: ScreenshotMonitor
    private let ocrService: ClipboardOCRService
    private let accessibilityAuthorizer: AccessibilityPasteAuthorizer
    private var archive: ClipboardArchive
    private var timer: Timer?
    private var workspaceObserver: NSObjectProtocol?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var lastExternalApplication: NSRunningApplication?
    private var undoItems: [ClipboardItem] = []
    private var undoCleanupWorkItem: DispatchWorkItem?
    private var statusClearWorkItem: DispatchWorkItem?
    private var ignoredScreenshotPaths = Set<String>()

    init(
        repository: ClipboardRepository? = nil,
        settings: Settings = .shared,
        retentionPolicy: ClipboardRetentionPolicy = ClipboardRetentionPolicy(),
        screenshotMonitor: ScreenshotMonitor = ScreenshotMonitor(),
        ocrService: ClipboardOCRService = ClipboardOCRService(),
        accessibilityAuthorizer: AccessibilityPasteAuthorizer = AccessibilityPasteAuthorizer()
    ) {
        self.settings = settings
        self.retentionPolicy = retentionPolicy
        self.screenshotMonitor = screenshotMonitor
        self.ocrService = ocrService
        self.accessibilityAuthorizer = accessibilityAuthorizer
        isPaused = settings.clipboardCapturePaused
        excludedApps = settings.excludedClipboardApps

        do {
            let resolvedRepository = try repository ?? ClipboardRepository()
            self.repository = resolvedRepository
            archive = try resolvedRepository.load()
            items = Self.sortedItems(archive.items)
        } catch {
            self.repository = nil
            archive = ClipboardArchive()
            storageErrorMessage = error.localizedDescription
        }
    }

    func start() {
        guard timer == nil else {
            return
        }

        DispatchQueue.global(qos: .utility).async {
            ClipboardDragExportStore.removeExpired()
        }

        lastChangeCount = NSPasteboard.general.changeCount
        startWorkspaceObservation()

        let now = Date()
        migrateLegacyHistoryIfNeeded(now: now)
        establishScreenshotCheckpointIfNeeded(now: now)
        if isPaused {
            markCaptureBaseline(at: now)
        } else {
            prune(now: now)
            captureNewScreenshots(through: now)
        }

        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.poll()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        ocrService.cancelPending()

        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        workspaceObserver = nil
        finalizeUndoDeletion()
    }

    func setPasteTarget(_ application: NSRunningApplication?) {
        guard
            let application,
            application.bundleIdentifier != Bundle.main.bundleIdentifier
        else {
            return
        }
        lastExternalApplication = application
    }

    func activate(_ item: ClipboardItem) {
        guard restoreToPasteboard(item) else {
            showStatus("This item is unavailable.")
            return
        }

        onRequestPanelClose?()
        guard let target = lastExternalApplication, !target.isTerminated else {
            showStatus("Copied to clipboard.")
            return
        }

        guard accessibilityAuthorizer.canPostPasteEvent() else {
            showStatus("Copied. Allow Accessibility to paste automatically.")
            return
        }

        target.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            Self.postCommandV()
        }
    }

    func itemProvider(for item: ClipboardItem) -> NSItemProvider {
        guard let payload = try? repository?.payload(for: item) else {
            return NSItemProvider()
        }

        switch item.kind {
        case .text:
            let provider = NSItemProvider()
            if let plainText = payload.plainText {
                provider.registerObject(plainText as NSString, visibility: .all)
            }
            Self.register(payload.rtfData, type: .rtf, on: provider)
            Self.register(payload.rtfdData, type: .rtfd, on: provider)
            Self.register(payload.htmlData, type: .html, on: provider)
            return provider
        case .file:
            guard let firstURL = payload.fileReferences.first?.resolvedURL else {
                return NSItemProvider()
            }
            return NSItemProvider(contentsOf: firstURL) ?? NSItemProvider()
        case .image, .screenshot:
            let provider = NSItemProvider()
            if let data = payload.imageData {
                let fileName = Self.imageFileName(for: item)
                provider.registerFileRepresentation(
                    forTypeIdentifier: UTType.png.identifier,
                    fileOptions: [],
                    visibility: .all
                ) { completion in
                    do {
                        let export = try ClipboardDragExportStore.makeExport(
                            data: data,
                            fileName: fileName
                        )
                        completion(export.fileURL, false, nil)
                    } catch {
                        completion(nil, false, error)
                    }
                    return nil
                }
                provider.registerDataRepresentation(
                    forTypeIdentifier: UTType.png.identifier,
                    visibility: .all
                ) { completion in
                    completion(data, nil)
                    return nil
                }
            }
            provider.suggestedName = (item.title as NSString).deletingPathExtension
            return provider
        }
    }

    func image(for item: ClipboardItem) -> NSImage? {
        guard
            let payload = try? repository?.payload(for: item),
            let imageData = payload.imageData
        else {
            return nil
        }
        return NSImage(data: imageData)
    }

    func payload(for item: ClipboardItem) -> ClipboardPayload? {
        try? repository?.payload(for: item)
    }

    func dragContent(for item: ClipboardItem) -> ClipboardDragContent {
        guard let payload = try? repository?.payload(for: item) else {
            return .empty
        }

        switch item.kind {
        case .text:
            let pasteboardItem = NSPasteboardItem()
            if let plainText = payload.plainText {
                pasteboardItem.setString(plainText, forType: .string)
            }
            if let data = payload.rtfData {
                pasteboardItem.setData(data, forType: .rtf)
            }
            if let data = payload.rtfdData {
                pasteboardItem.setData(data, forType: .rtfd)
            }
            if let data = payload.htmlData {
                pasteboardItem.setData(data, forType: .html)
            }
            return ClipboardDragContent(writers: [pasteboardItem])
        case .file:
            let writers = payload.fileReferences
                .map(\.resolvedURL)
                .filter { FileManager.default.fileExists(atPath: $0.path) }
                .map { $0 as NSURL }
            return ClipboardDragContent(writers: writers)
        case .image, .screenshot:
            guard let imageData = payload.imageData else {
                return .empty
            }
            let pasteboardItem = Self.imagePasteboardItem(data: imageData)
            do {
                let export = try ClipboardDragExportStore.makeExport(
                    data: imageData,
                    fileName: Self.imageFileName(for: item)
                )
                pasteboardItem.setString(export.fileURL.absoluteString, forType: .fileURL)
                return ClipboardDragContent(writers: [pasteboardItem])
            } catch {
                return ClipboardDragContent(writers: [pasteboardItem])
            }
        }
    }

    func completeSuccessfulDrag() {
        onRequestPanelClose?()
    }

    func togglePaused() {
        isPaused.toggle()
        settings.clipboardCapturePaused = isPaused
        markCaptureBaseline(at: Date())
        if isPaused {
            ocrService.cancelPending()
            showStatus("Clipboard capture paused.")
        } else {
            showStatus("Clipboard capture resumed.")
        }
    }

    func pin(_ ids: Set<UUID>, at date: Date = Date()) {
        mutateItems { items in
            for index in items.indices where ids.contains(items[index].id) {
                if items[index].pinnedAt == nil {
                    items[index].pinnedAt = date
                }
            }
        }
    }

    func unpin(_ ids: Set<UUID>, at date: Date = Date()) {
        mutateItems { items in
            for index in items.indices where ids.contains(items[index].id) {
                items[index].pinnedAt = nil
                items[index].capturedAt = date
            }
        }
    }

    func delete(_ ids: Set<UUID>) {
        let deleting = archive.items.filter { ids.contains($0.id) }
        guard !deleting.isEmpty else {
            return
        }

        finalizeUndoDeletion()
        var candidate = archive
        candidate.items.removeAll { ids.contains($0.id) }
        guard persist(candidate) else {
            return
        }

        undoItems = deleting
        canUndoDeletion = true
        let workItem = DispatchWorkItem { [weak self] in
            self?.finalizeUndoDeletion()
        }
        undoCleanupWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
    }

    func clearUnpinned() {
        delete(Set(archive.items.filter { !$0.isPinned }.map(\.id)))
    }

    func clearEverything() {
        delete(Set(archive.items.map(\.id)))
    }

    func undoDeletion() {
        guard !undoItems.isEmpty else {
            return
        }

        undoCleanupWorkItem?.cancel()
        var candidate = archive
        let existingIDs = Set(candidate.items.map(\.id))
        candidate.items.append(contentsOf: undoItems.filter { !existingIDs.contains($0.id) })
        guard persist(candidate) else {
            return
        }

        undoItems = []
        canUndoDeletion = false
        undoCleanupWorkItem = nil
    }

    func addExcludedApplication(url: URL) {
        guard
            let bundle = Bundle(url: url),
            let identifier = bundle.bundleIdentifier
        else {
            return
        }

        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        addExcludedApplication(
            ExcludedClipboardApp(bundleIdentifier: identifier, displayName: name)
        )
    }

    func excludePasteTarget() {
        guard
            let application = lastExternalApplication,
            let identifier = application.bundleIdentifier
        else {
            return
        }
        addExcludedApplication(
            ExcludedClipboardApp(
                bundleIdentifier: identifier,
                displayName: application.localizedName ?? identifier
            )
        )
    }

    func removeExcludedApplication(_ app: ExcludedClipboardApp) {
        excludedApps.removeAll { $0.bundleIdentifier == app.bundleIdentifier }
        saveExcludedApps()
    }

    func focus(_ itemID: UUID) {
        requestedFocusItemID = nil
        DispatchQueue.main.async { [weak self] in
            self?.requestedFocusItemID = itemID
        }
    }

    @discardableResult
    func ingestSnippet(at url: URL, date: Date = Date()) -> ClipboardItem? {
        if isPaused {
            markScreenshotCheckpoint(at: date)
        } else {
            let path = url.standardizedFileURL.path
            ignoredScreenshotPaths.insert(path)
            captureNewScreenshots(through: date)
            ignoredScreenshotPaths.remove(path)
        }

        guard
            let capture = ClipboardCaptureReader.screenshot(
                url: url,
                sourceAppName: "Silverdeck Snippet",
                sourceBundleIdentifier: Bundle.main.bundleIdentifier
            ),
            let image = NSImage(contentsOf: url),
            let item = insert(capture, at: date, schedulesOCR: true)
        else {
            return nil
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        lastChangeCount = pasteboard.changeCount
        onScreenshotCaptured?(item, image)
        return item
    }

    private func poll() {
        let now = Date()
        captureClipboardChangeIfNeeded()

        if isPaused {
            markScreenshotCheckpoint(at: now)
            ignoredScreenshotPaths.removeAll()
            return
        }

        captureNewScreenshots(through: now)
        prune(now: now)
    }

    private func captureClipboardChangeIfNeeded() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else {
            return
        }
        lastChangeCount = pasteboard.changeCount
        guard !isPaused else {
            return
        }

        let sourceApplication = lastExternalApplication
            ?? NSWorkspace.shared.frontmostApplication
        if
            let bundleIdentifier = sourceApplication?.bundleIdentifier,
            excludedApps.contains(where: { $0.bundleIdentifier == bundleIdentifier })
        {
            return
        }

        guard let capture = ClipboardCaptureReader.capture(
            from: pasteboard,
            sourceApplication: sourceApplication
        ) else {
            return
        }
        _ = insert(capture, at: Date(), schedulesOCR: true)
    }

    private func captureNewScreenshots(through now: Date) {
        guard
            let activatedAt = archive.phaseThreeActivatedAt,
            let lastScanAt = archive.lastScreenshotScanAt
        else {
            establishScreenshotCheckpointIfNeeded(now: now)
            return
        }

        let scanStart = max(activatedAt, lastScanAt)
        let urls = screenshotMonitor.screenshots(createdAfter: scanStart, through: now)
        markScreenshotCheckpoint(at: now)

        for url in urls {
            if ignoredScreenshotPaths.remove(url.standardizedFileURL.path) != nil {
                continue
            }
            guard
                let capture = ClipboardCaptureReader.screenshot(url: url),
                let item = insert(capture, at: Date(), schedulesOCR: true),
                let image = NSImage(contentsOf: url)
            else {
                continue
            }
            onScreenshotCaptured?(item, image)
        }
    }

    @discardableResult
    private func insert(
        _ capture: ClipboardCapture,
        at date: Date,
        schedulesOCR: Bool
    ) -> ClipboardItem? {
        guard let repository else {
            return nil
        }

        var candidate = archive
        let existingIndex = candidate.items.firstIndex { $0.signature == capture.signature }
        var item: ClipboardItem

        if let existingIndex {
            item = candidate.items[existingIndex]
            item.kind = capture.kind
            item.title = capture.title
            item.subtitle = capture.subtitle
            item.sourceAppName = capture.sourceAppName
            item.sourceBundleIdentifier = capture.sourceBundleIdentifier
            item.capturedAt = date
            item.searchText = capture.searchText
            item.ocrText = candidate.items[existingIndex].ocrText
            do {
                item.storedByteCount = try repository.savePayload(
                    capture.payload,
                    id: item.payloadID
                )
            } catch {
                storageErrorMessage = error.localizedDescription
                return nil
            }
            candidate.items[existingIndex] = item
        } else {
            item = capture.makeItem(at: date)
            do {
                item.storedByteCount = try repository.savePayload(
                    capture.payload,
                    id: item.payloadID
                )
            } catch {
                storageErrorMessage = error.localizedDescription
                return nil
            }
            candidate.items.append(item)
        }

        guard persist(candidate) else {
            return nil
        }
        prune(now: date)

        if schedulesOCR, let imageData = capture.payload.imageData {
            scheduleOCR(imageData: imageData, itemID: item.id)
        }
        return archive.items.first { $0.id == item.id }
    }

    private func scheduleOCR(imageData: Data, itemID: UUID) {
        ocrService.recognizeText(in: imageData, itemID: itemID) { [weak self] id, text in
            guard let self, !self.isPaused, let text else {
                return
            }
            self.mutateItems { items in
                guard let index = items.firstIndex(where: { $0.id == id }) else {
                    return
                }
                items[index].ocrText = text
            }
        }
    }

    private func migrateLegacyHistoryIfNeeded(now: Date) {
        guard let repository else {
            return
        }

        let captures = repository.legacyCaptures(now: now)
        for capture in captures {
            _ = insert(capture, at: now, schedulesOCR: false)
        }

        do {
            try repository.save(archive)
            let verifiedArchive = try repository.load()
            guard Set(verifiedArchive.items.map(\.id)) == Set(archive.items.map(\.id)) else {
                return
            }
            repository.removeLegacyArchives()
        } catch {
            storageErrorMessage = error.localizedDescription
        }
    }

    private func establishScreenshotCheckpointIfNeeded(now: Date) {
        guard archive.phaseThreeActivatedAt == nil else {
            return
        }

        var candidate = archive
        candidate.phaseThreeActivatedAt = now
        candidate.lastScreenshotScanAt = now
        _ = persist(candidate)
    }

    private func markCaptureBaseline(at date: Date) {
        lastChangeCount = NSPasteboard.general.changeCount
        markScreenshotCheckpoint(at: date)
    }

    private func markScreenshotCheckpoint(at date: Date) {
        var candidate = archive
        candidate.lastScreenshotScanAt = date
        if candidate.phaseThreeActivatedAt == nil {
            candidate.phaseThreeActivatedAt = date
        }
        _ = persist(candidate)
    }

    private func prune(now: Date) {
        let removalIDs = retentionPolicy.removalIDs(from: archive.items, now: now)
        guard !removalIDs.isEmpty else {
            return
        }

        let removedItems = archive.items.filter { removalIDs.contains($0.id) }
        var candidate = archive
        candidate.items.removeAll { removalIDs.contains($0.id) }
        guard persist(candidate) else {
            return
        }
        repository?.removePayloads(for: removedItems)
    }

    private func mutateItems(_ mutation: (inout [ClipboardItem]) -> Void) {
        var candidate = archive
        mutation(&candidate.items)
        _ = persist(candidate)
    }

    @discardableResult
    private func persist(_ candidate: ClipboardArchive) -> Bool {
        guard let repository else {
            return false
        }

        do {
            try repository.save(candidate)
            archive = candidate
            items = Self.sortedItems(candidate.items)
            storageErrorMessage = nil
            return true
        } catch {
            storageErrorMessage = error.localizedDescription
            return false
        }
    }

    func restoreToPasteboard(
        _ item: ClipboardItem,
        pasteboard: NSPasteboard = .general
    ) -> Bool {
        guard let payload = try? repository?.payload(for: item) else {
            return false
        }

        pasteboard.clearContents()

        switch item.kind {
        case .text:
            let pasteboardItem = NSPasteboardItem()
            if let plainText = payload.plainText {
                pasteboardItem.setString(plainText, forType: .string)
            }
            if let data = payload.rtfData {
                pasteboardItem.setData(data, forType: .rtf)
            }
            if let data = payload.rtfdData {
                pasteboardItem.setData(data, forType: .rtfd)
            }
            if let data = payload.htmlData {
                pasteboardItem.setData(data, forType: .html)
            }
            pasteboard.writeObjects([pasteboardItem])
        case .file:
            let urls = payload.fileReferences
                .map(\.resolvedURL)
                .filter { FileManager.default.fileExists(atPath: $0.path) } as [NSURL]
            guard !urls.isEmpty else {
                return false
            }
            pasteboard.writeObjects(urls)
        case .image, .screenshot:
            guard let imageData = payload.imageData else {
                return false
            }
            guard pasteboard.writeObjects([Self.imagePasteboardItem(data: imageData)]) else {
                return false
            }
        }

        if pasteboard === NSPasteboard.general {
            lastChangeCount = pasteboard.changeCount
        }
        return true
    }

    private func startWorkspaceObservation() {
        let workspace = NSWorkspace.shared
        let current = workspace.frontmostApplication
        setPasteTarget(current)

        workspaceObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication
            else {
                return
            }
            Task { @MainActor in
                self?.setPasteTarget(application)
            }
        }
    }

    private func addExcludedApplication(_ app: ExcludedClipboardApp) {
        excludedApps.removeAll { $0.bundleIdentifier == app.bundleIdentifier }
        excludedApps.append(app)
        excludedApps.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        saveExcludedApps()
    }

    private func saveExcludedApps() {
        settings.excludedClipboardApps = excludedApps
    }

    private func finalizeUndoDeletion() {
        undoCleanupWorkItem?.cancel()
        repository?.removePayloads(for: undoItems)
        undoItems = []
        canUndoDeletion = false
        undoCleanupWorkItem = nil
    }

    private func showStatus(_ message: String) {
        statusClearWorkItem?.cancel()
        statusMessage = message
        let workItem = DispatchWorkItem { [weak self] in
            self?.statusMessage = nil
        }
        statusClearWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: workItem)
    }

    private static func sortedItems(_ items: [ClipboardItem]) -> [ClipboardItem] {
        items.sorted { lhs, rhs in
            switch (lhs.pinnedAt, rhs.pinnedAt) {
            case let (lhsDate?, rhsDate?):
                return lhsDate > rhsDate
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.capturedAt > rhs.capturedAt
            }
        }
    }

    private static func register(
        _ data: Data?,
        type: NSPasteboard.PasteboardType,
        on provider: NSItemProvider
    ) {
        guard let data else {
            return
        }
        provider.registerDataRepresentation(
            forTypeIdentifier: type.rawValue,
            visibility: .all
        ) { completion in
            completion(data, nil)
            return nil
        }
    }

    private static func imagePasteboardItem(data: Data) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setData(data, forType: .png)
        if let image = NSImage(data: data), let tiffData = image.tiffRepresentation {
            item.setData(tiffData, forType: .tiff)
        }
        return item
    }

    private static func imageFileName(for item: ClipboardItem) -> String {
        let baseName = (item.title as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeBaseName = (baseName.isEmpty ? "Silverdeck Image" : baseName)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "\(safeBaseName).png"
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: 9,
            keyDown: true
        )
        let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: 9,
            keyDown: false
        )
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}

final class ClipboardDragContent {
    static let empty = ClipboardDragContent(writers: [])

    let writers: [NSPasteboardWriting]
    private let cleanup: (() -> Void)?

    init(
        writers: [NSPasteboardWriting],
        cleanup: (() -> Void)? = nil
    ) {
        self.writers = writers
        self.cleanup = cleanup
    }

    deinit {
        cleanup?()
    }
}
