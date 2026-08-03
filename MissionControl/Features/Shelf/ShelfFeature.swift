import AppKit
import Combine
import Foundation

final class ShelfFeature: ObservableObject {
    static let shared = ShelfFeature()

    @Published private(set) var items: [ShelfItem]

    private let store: ShelfStore
    private var archive: ShelfArchive

    init(store: ShelfStore = ShelfStore()) {
        self.store = store
        archive = store.load()
        items = archive.items.sorted(by: ShelfFeature.sortItems)
        refreshResolvedReferences()
    }

    @discardableResult
    func add(_ urls: [URL], at date: Date = Date()) -> Int {
        let normalizedURLs = uniqueNormalizedFileURLs(urls)
        guard !normalizedURLs.isEmpty else {
            return 0
        }

        var candidate = archive
        for url in normalizedURLs.reversed() {
            let normalizedPath = url.normalizedFilePath
            let existing = candidate.items.first { $0.normalizedPath == normalizedPath }
            candidate.items.removeAll { $0.normalizedPath == normalizedPath }
            candidate.nextOrder &+= 1
            candidate.items.append(
                ShelfItem(
                    id: existing?.id ?? UUID(),
                    url: url,
                    addedAt: date,
                    order: candidate.nextOrder
                )
            )
        }
        candidate.items.sort(by: ShelfFeature.sortItems)

        guard store.save(candidate) else {
            return 0
        }

        archive = candidate
        items = candidate.items
        return normalizedURLs.count
    }

    func remove(_ item: ShelfItem) {
        var candidate = archive
        candidate.items.removeAll { $0.id == item.id }
        guard store.save(candidate) else {
            return
        }

        archive = candidate
        items = candidate.items
    }

    func open(_ item: ShelfItem) {
        guard item.exists else {
            return
        }

        NSWorkspace.shared.open(item.resolvedURL)
    }

    func reveal(_ item: ShelfItem) {
        guard item.exists else {
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([item.resolvedURL])
    }

    func copyPath(_ item: ShelfItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.resolvedURL.path, forType: .string)
    }

    private func refreshResolvedReferences() {
        var candidate = archive
        var changed = false

        for index in candidate.items.indices {
            changed = candidate.items[index].refreshResolvedReference() || changed
        }
        candidate.items.sort(by: ShelfFeature.sortItems)

        if changed, store.save(candidate) {
            archive = candidate
            items = candidate.items
        }
    }

    private func uniqueNormalizedFileURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.compactMap { url in
            guard url.isFileURL else {
                return nil
            }

            let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
            guard seen.insert(normalized.path).inserted else {
                return nil
            }

            return normalized
        }
    }

    private static func sortItems(_ lhs: ShelfItem, _ rhs: ShelfItem) -> Bool {
        if lhs.order == rhs.order {
            return lhs.lastKnownPath.localizedStandardCompare(rhs.lastKnownPath) == .orderedAscending
        }

        return lhs.order > rhs.order
    }
}

struct ShelfArchive: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion = currentSchemaVersion
    var nextOrder: UInt64 = 0
    var items: [ShelfItem] = []
}

struct ShelfItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case file
        case folder
    }

    let id: UUID
    var bookmarkData: Data?
    var lastKnownPath: String
    var displayName: String
    var kind: Kind
    var addedAt: Date
    var order: UInt64

    init(id: UUID = UUID(), url: URL, addedAt: Date, order: UInt64) {
        self.id = id
        bookmarkData = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: [.isDirectoryKey, .nameKey],
            relativeTo: nil
        )
        lastKnownPath = url.normalizedFilePath
        displayName = url.lastPathComponent
        kind = url.isDirectory ? .folder : .file
        self.addedAt = addedAt
        self.order = order
    }

    var normalizedPath: String {
        URL(fileURLWithPath: lastKnownPath).normalizedFilePath
    }

    var resolvedURL: URL {
        let lastKnownURL = URL(fileURLWithPath: lastKnownPath).standardizedFileURL
        if FileManager.default.fileExists(atPath: lastKnownURL.path) {
            return lastKnownURL
        }

        guard let bookmarkData else {
            return lastKnownURL
        }

        var isStale = false
        return (try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )) ?? lastKnownURL
    }

    var exists: Bool {
        FileManager.default.fileExists(atPath: resolvedURL.path)
    }

    var parentPath: String {
        resolvedURL.deletingLastPathComponent().path
    }

    var formattedTime: String {
        addedAt.formatted(date: .abbreviated, time: .shortened)
    }

    var dragSuggestedName: String {
        kind == .file ? (displayName as NSString).deletingPathExtension : displayName
    }

    @discardableResult
    mutating func refreshResolvedReference() -> Bool {
        if FileManager.default.fileExists(atPath: lastKnownPath) {
            return false
        }

        guard let bookmarkData else {
            return false
        }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return false
        }

        let newPath = url.normalizedFilePath
        let newName = url.lastPathComponent
        var changed = newPath != lastKnownPath || newName != displayName
        lastKnownPath = newPath
        displayName = newName
        kind = url.isDirectory ? .folder : .file

        if isStale, let refreshed = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: [.isDirectoryKey, .nameKey],
            relativeTo: nil
        ) {
            self.bookmarkData = refreshed
            changed = true
        }

        return changed
    }
}

final class ShelfStore {
    private let fileManager: FileManager
    private let fileURL: URL
    private var acceptsWrites = true

    init(fileManager: FileManager = .default, fileURL: URL? = nil) {
        self.fileManager = fileManager

        if let fileURL {
            self.fileURL = fileURL
        } else {
            let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.fileURL = baseURL
                .appendingPathComponent("Droppy", isDirectory: true)
                .appendingPathComponent("Shelf.json")
        }

        try? fileManager.createDirectory(
            at: self.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    func load() -> ShelfArchive {
        guard let data = try? Data(contentsOf: fileURL) else {
            return ShelfArchive()
        }

        do {
            let archive = try JSONDecoder.shelf.decode(ShelfArchive.self, from: data)
            guard archive.schemaVersion == ShelfArchive.currentSchemaVersion else {
                acceptsWrites = false
                return ShelfArchive()
            }
            return archive
        } catch {
            backupUnreadableStore()
            return ShelfArchive()
        }
    }

    @discardableResult
    func save(_ archive: ShelfArchive) -> Bool {
        guard acceptsWrites, let data = try? JSONEncoder.shelf.encode(archive) else {
            return false
        }

        do {
            try data.write(to: fileURL, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    private func backupUnreadableStore() {
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backupURL = fileURL
            .deletingPathExtension()
            .appendingPathExtension("corrupt-\(timestamp).json")
        try? fileManager.moveItem(at: fileURL, to: backupURL)
    }
}

private extension URL {
    var normalizedFilePath: String {
        standardizedFileURL.resolvingSymlinksInPath().path
    }

    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

private extension JSONEncoder {
    static var shelf: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var shelf: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
