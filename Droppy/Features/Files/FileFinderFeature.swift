import AppKit
import Combine
import QuickLookUI
import SwiftUI

struct FavoriteFolder: Identifiable, Codable, Equatable {
    let id: UUID
    var bookmarkData: Data?
    var lastKnownPath: String
    var displayName: String

    init(id: UUID = UUID(), url: URL) {
        let normalizedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        self.id = id
        bookmarkData = try? normalizedURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: [.isDirectoryKey, .nameKey],
            relativeTo: nil
        )
        lastKnownPath = normalizedURL.path
        displayName = normalizedURL.lastPathComponent
    }

    var resolvedURL: URL {
        let fallbackURL = URL(
            fileURLWithPath: lastKnownPath,
            isDirectory: true
        ).standardizedFileURL
        if FileManager.default.fileExists(atPath: fallbackURL.path) {
            return fallbackURL
        }

        guard let bookmarkData else {
            return fallbackURL
        }
        var isStale = false
        return (try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )) ?? fallbackURL
    }

    var exists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: resolvedURL.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }

    @discardableResult
    mutating func refreshResolvedReference() -> Bool {
        guard let bookmarkData else {
            return false
        }
        var isStale = false
        guard let resolvedURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return false
        }

        let normalizedURL = resolvedURL.standardizedFileURL
            .resolvingSymlinksInPath()
        let newPath = normalizedURL.path
        let newName = normalizedURL.lastPathComponent
        var changed = newPath != lastKnownPath || newName != displayName
        lastKnownPath = newPath
        displayName = newName

        if isStale, let refreshedBookmark = try? normalizedURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: [.isDirectoryKey, .nameKey],
            relativeTo: nil
        ) {
            self.bookmarkData = refreshedBookmark
            changed = true
        }
        return changed
    }
}

struct FileFinderItem: Identifiable, Equatable {
    let url: URL
    let isDirectory: Bool
    let modificationDate: Date?
    let byteCount: Int64?

    var id: String { url.standardizedFileURL.path }
    var displayName: String { url.lastPathComponent }
    var parentPath: String { url.deletingLastPathComponent().path }

    var detail: String {
        if isDirectory {
            return parentPath
        }
        if let byteCount {
            return ByteCountFormatter.string(
                fromByteCount: byteCount,
                countStyle: .file
            )
        }
        return parentPath
    }
}

struct FileFinderArchive: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion = currentSchemaVersion
    var selectedFavoriteID: UUID?
    var favorites: [FavoriteFolder] = []
}

enum FileFinderStoreLoadResult {
    case missing
    case loaded(FileFinderArchive)
    case failed
}

final class FileFinderStore {
    private let fileURL: URL
    private let fileManager: FileManager
    private(set) var acceptsWrites = true

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let baseURL = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.temporaryDirectory
            self.fileURL = baseURL
                .appendingPathComponent("Droppy", isDirectory: true)
                .appendingPathComponent("FileFavorites.json")
        }
        try? fileManager.createDirectory(
            at: self.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    func load() -> FileFinderStoreLoadResult {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return .missing
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let archive = try JSONDecoder().decode(
                FileFinderArchive.self,
                from: data
            )
            guard archive.schemaVersion == FileFinderArchive.currentSchemaVersion
            else {
                acceptsWrites = false
                return .failed
            }
            return .loaded(archive)
        } catch {
            acceptsWrites = false
            return .failed
        }
    }

    @discardableResult
    func save(_ archive: FileFinderArchive) -> Bool {
        guard acceptsWrites else {
            return false
        }
        guard let data = try? Self.encoder.encode(archive) else {
            return false
        }
        do {
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

}

enum FileFinderScanner {
    static func scan(
        rootURL: URL,
        query: String,
        maximumResults: Int = 200,
        fileManager: FileManager = .default,
        isCancelled: () -> Bool = { false }
    ) -> [FileFinderItem] {
        guard !isCancelled() else {
            return []
        }
        let normalizedQuery = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .contentModificationDateKey,
            .fileSizeKey,
            .isPackageKey,
        ]

        if normalizedQuery.isEmpty {
            let urls = (try? fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )) ?? []
            return sortedItems(
                urls.prefix(while: { _ in !isCancelled() })
                    .compactMap { item(for: $0, keys: keys) }
            )
        }

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var results: [FileFinderItem] = []
        while
            let url = enumerator.nextObject() as? URL,
            results.count < maximumResults,
            !isCancelled()
        {
            let relativePath = url.path.replacingOccurrences(
                of: rootURL.path,
                with: ""
            )
            guard
                url.lastPathComponent.localizedCaseInsensitiveContains(
                    normalizedQuery
                )
                    || relativePath.localizedCaseInsensitiveContains(
                        normalizedQuery
                    ),
                let item = item(for: url, keys: keys)
            else {
                continue
            }
            results.append(item)
        }
        return sortedItems(results)
    }

    private static func item(
        for url: URL,
        keys: Set<URLResourceKey>
    ) -> FileFinderItem? {
        guard let values = try? url.resourceValues(forKeys: keys) else {
            return nil
        }
        let isDirectory = values.isDirectory == true
        guard isDirectory || values.isRegularFile == true else {
            return nil
        }
        return FileFinderItem(
            url: url.standardizedFileURL,
            isDirectory: isDirectory,
            modificationDate: values.contentModificationDate,
            byteCount: values.fileSize.map(Int64.init)
        )
    }

    private static func sortedItems(
        _ items: [FileFinderItem]
    ) -> [FileFinderItem] {
        items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            return lhs.displayName.localizedStandardCompare(rhs.displayName)
                == .orderedAscending
        }
    }
}

final class FileFinderScanToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

@MainActor
final class FileFinderFeature: ObservableObject {
    static let shared = FileFinderFeature()

    @Published private(set) var favorites: [FavoriteFolder]
    @Published var selectedFavoriteID: UUID? {
        didSet {
            guard selectedFavoriteID != oldValue else { return }
            persist()
            reload()
        }
    }
    @Published private(set) var items: [FileFinderItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            reload()
        }
    }

    private let store: FileFinderStore
    private var scanGeneration = 0
    private var scanToken: FileFinderScanToken?
    private var persistenceErrorMessage: String?

    init(
        store: FileFinderStore = FileFinderStore(),
        defaultFavorites: [URL]? = nil
    ) {
        self.store = store
        let loadResult = store.load()
        var archive: FileFinderArchive
        switch loadResult {
        case .missing:
            archive = FileFinderArchive()
        case let .loaded(savedArchive):
            archive = savedArchive
        case .failed:
            archive = FileFinderArchive()
        }
        var initialErrorMessage: String?
        if case .loaded = loadResult {
            var refreshed = false
            for index in archive.favorites.indices {
                refreshed =
                    archive.favorites[index].refreshResolvedReference()
                    || refreshed
            }
            if refreshed, !store.save(archive) {
                initialErrorMessage =
                    "Updated folder favorites could not be saved."
            }
        }
        if archive.favorites.isEmpty {
            archive.favorites = Self.makeDefaultFavorites(
                urls: defaultFavorites
            )
            archive.selectedFavoriteID = archive.favorites.first?.id
            if case .missing = loadResult {
                store.save(archive)
            }
        }
        favorites = archive.favorites
        selectedFavoriteID = archive.selectedFavoriteID
            ?? archive.favorites.first?.id
        if case .failed = loadResult {
            initialErrorMessage =
                "Saved folder favorites could not be read. They were left untouched."
        }
        persistenceErrorMessage = initialErrorMessage
        errorMessage = initialErrorMessage
        reload()
    }

    var selectedFavorite: FavoriteFolder? {
        favorites.first { $0.id == selectedFavoriteID }
    }

    var selectedDirectoryURL: URL {
        selectedFavorite?.resolvedURL
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    func addFavorite(_ url: URL) {
        let normalizedPath = url.standardizedFileURL
            .resolvingSymlinksInPath().path
        if let existing = favorites.first(where: {
            $0.resolvedURL.path == normalizedPath
        }) {
            selectedFavoriteID = existing.id
            return
        }
        let favorite = FavoriteFolder(url: url)
        favorites.append(favorite)
        selectedFavoriteID = favorite.id
        persist()
    }

    func removeSelectedFavorite() {
        guard let selectedFavoriteID else { return }
        favorites.removeAll { $0.id == selectedFavoriteID }
        self.selectedFavoriteID = favorites.first?.id
        persist()
        reload()
    }

    func reload() {
        scanToken?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        let token = FileFinderScanToken()
        scanToken = token
        let rootURL = selectedDirectoryURL
        let query = searchText
        isLoading = true
        errorMessage = persistenceErrorMessage

        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + 0.18
        ) { [weak self] in
            guard !token.isCancelled else {
                return
            }
            let rootExists = FileManager.default.fileExists(
                atPath: rootURL.path
            )
            let results = rootExists
                ? FileFinderScanner.scan(
                    rootURL: rootURL,
                    query: query,
                    isCancelled: { token.isCancelled }
                )
                : []
            DispatchQueue.main.async {
                guard let self, generation == self.scanGeneration else {
                    return
                }
                self.items = results
                self.isLoading = false
                if !rootExists {
                    self.errorMessage = "This favorite folder is unavailable."
                } else {
                    self.errorMessage = self.persistenceErrorMessage
                }
            }
        }
    }

    func open(_ item: FileFinderItem) {
        NSWorkspace.shared.open(item.url)
    }

    func reveal(_ item: FileFinderItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func copyPath(_ item: FileFinderItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.url.path, forType: .string)
    }

    func quickLook(_ item: FileFinderItem) {
        QuickLookPreviewController.shared.show(url: item.url)
    }

    private func persist() {
        let saved = store.save(
            FileFinderArchive(
                selectedFavoriteID: selectedFavoriteID,
                favorites: favorites
            )
        )
        if !saved {
            persistenceErrorMessage =
                "Folder favorites could not be saved. Existing data was left untouched."
        } else {
            persistenceErrorMessage = nil
        }
        errorMessage = persistenceErrorMessage
    }

    private static func makeDefaultFavorites(
        urls: [URL]?
    ) -> [FavoriteFolder] {
        let fileManager = FileManager.default
        let candidates: [URL]
        if let urls {
            candidates = urls
        } else {
            var defaults = [
                fileManager.urls(
                    for: .downloadsDirectory,
                    in: .userDomainMask
                ).first,
                fileManager.urls(
                    for: .documentDirectory,
                    in: .userDomainMask
                ).first,
                fileManager.urls(
                    for: .desktopDirectory,
                    in: .userDomainMask
                ).first,
                ScreenshotMonitor().preferredSaveFolder(),
            ].compactMap { $0 }
            defaults = defaults.filter {
                fileManager.fileExists(atPath: $0.path)
            }
            candidates = defaults
        }

        var seen = Set<String>()
        return candidates.compactMap { url in
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard seen.insert(path).inserted else {
                return nil
            }
            return FavoriteFolder(url: url)
        }
    }
}

private final class QuickLookPreviewController: NSObject,
    QLPreviewPanelDataSource
{
    static let shared = QuickLookPreviewController()

    private var previewURL: URL?

    func show(url: URL) {
        previewURL = url
        guard let panel = QLPreviewPanel.shared() else {
            NSWorkspace.shared.open(url)
            return
        }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(
        _ panel: QLPreviewPanel!,
        previewItemAt index: Int
    ) -> QLPreviewItem! {
        previewURL as NSURL?
    }
}

struct FileFinderView: View {
    @ObservedObject var feature: FileFinderFeature

    var body: some View {
        VStack(spacing: 0) {
            controls
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Divider()

            if let errorMessage = feature.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }

            if feature.isLoading && feature.items.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if feature.items.isEmpty {
                emptyState
            } else {
                fileList
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Picker(
                    "Favorite folder",
                    selection: $feature.selectedFavoriteID
                ) {
                    ForEach(feature.favorites) { favorite in
                        Label(
                            favorite.displayName,
                            systemImage: "folder"
                        )
                        .tag(Optional(favorite.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)

                Button {
                    chooseFolder()
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Add favorite folder")

                Button {
                    feature.removeSelectedFavorite()
                } label: {
                    Image(systemName: "minus.circle")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Remove favorite folder")
                .disabled(feature.selectedFavoriteID == nil)

                Button {
                    feature.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search this folder", text: $feature.searchText)
                    .textFieldStyle(.plain)
                if !feature.searchText.isEmpty {
                    Button {
                        feature.searchText = ""
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
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(feature.items) { item in
                    FileFinderRow(item: item, feature: feature)
                }
            }
            .padding(14)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: feature.searchText.isEmpty
                ? "folder"
                : "doc.text.magnifyingglass")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(feature.searchText.isEmpty
                ? "This folder is empty"
                : "No matching files")
                .font(.system(size: 14, weight: .semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a favorite folder"
        panel.prompt = "Add"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        feature.addFavorite(url)
    }
}

private struct FileFinderRow: View {
    let item: FileFinderItem
    @ObservedObject var feature: FileFinderFeature

    var body: some View {
        HStack(spacing: 10) {
            Button {
                feature.open(item)
            } label: {
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                        .resizable()
                        .scaledToFit()
                        .frame(width: 30, height: 30)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text(item.detail)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onDrag {
                let provider = NSItemProvider(contentsOf: item.url)
                    ?? NSItemProvider()
                provider.suggestedName = item.isDirectory
                    ? item.displayName
                    : (item.displayName as NSString).deletingPathExtension
                return provider
            }
            .contextMenu {
                Button("Open") { feature.open(item) }
                Button("Quick Look") { feature.quickLook(item) }
                Button("Reveal in Finder") { feature.reveal(item) }
                Button("Copy Path") { feature.copyPath(item) }
            }

            Button {
                feature.quickLook(item)
            } label: {
                Image(systemName: "eye")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Quick Look")
        }
        .padding(9)
        .background(
            .thinMaterial,
            in: RoundedRectangle(cornerRadius: 8)
        )
    }
}
