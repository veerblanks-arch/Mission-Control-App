import CryptoKit
import Foundation

struct ClipboardItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case text
        case image
        case file
        case screenshot
    }

    let id: UUID
    var kind: Kind
    var title: String
    var subtitle: String
    var sourceAppName: String
    var sourceBundleIdentifier: String?
    var createdAt: Date
    var capturedAt: Date
    var pinnedAt: Date?
    var signature: String
    var payloadID: UUID
    var storedByteCount: Int64
    var searchText: String
    var ocrText: String?

    var isPinned: Bool {
        pinnedAt != nil
    }

    var formattedTime: String {
        capturedAt.formatted(date: .omitted, time: .shortened)
    }

    var searchableContent: String {
        [
            title,
            subtitle,
            sourceAppName,
            searchText,
            ocrText ?? "",
        ].joined(separator: "\n")
    }
}

struct ClipboardPayload: Codable, Equatable {
    var plainText: String?
    var rtfData: Data?
    var rtfdData: Data?
    var htmlData: Data?
    var fileReferences: [ClipboardFileReference]
    var imageData: Data?
    var imageTypeIdentifier: String?
    var screenshotOriginalPath: String?

    static func text(
        plainText: String,
        rtfData: Data?,
        rtfdData: Data?,
        htmlData: Data?
    ) -> ClipboardPayload {
        ClipboardPayload(
            plainText: plainText,
            rtfData: rtfData,
            rtfdData: rtfdData,
            htmlData: htmlData,
            fileReferences: [],
            imageData: nil,
            imageTypeIdentifier: nil,
            screenshotOriginalPath: nil
        )
    }

    static func files(_ references: [ClipboardFileReference]) -> ClipboardPayload {
        ClipboardPayload(
            plainText: nil,
            rtfData: nil,
            rtfdData: nil,
            htmlData: nil,
            fileReferences: references,
            imageData: nil,
            imageTypeIdentifier: nil,
            screenshotOriginalPath: nil
        )
    }

    static func image(
        data: Data,
        typeIdentifier: String,
        screenshotOriginalPath: String? = nil
    ) -> ClipboardPayload {
        ClipboardPayload(
            plainText: nil,
            rtfData: nil,
            rtfdData: nil,
            htmlData: nil,
            fileReferences: [],
            imageData: data,
            imageTypeIdentifier: typeIdentifier,
            screenshotOriginalPath: screenshotOriginalPath
        )
    }
}

struct ClipboardFileReference: Codable, Equatable {
    var bookmarkData: Data?
    var lastKnownPath: String
    var displayName: String
    var isDirectory: Bool

    init(url: URL) {
        let normalizedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        bookmarkData = try? normalizedURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: [.isDirectoryKey, .nameKey],
            relativeTo: nil
        )
        lastKnownPath = normalizedURL.path
        displayName = normalizedURL.lastPathComponent
        isDirectory = (try? normalizedURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    var resolvedURL: URL {
        let fallbackURL = URL(fileURLWithPath: lastKnownPath).standardizedFileURL
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
}

struct ClipboardCapture {
    var kind: ClipboardItem.Kind
    var title: String
    var subtitle: String
    var sourceAppName: String
    var sourceBundleIdentifier: String?
    var payload: ClipboardPayload
    var signature: String
    var searchText: String

    func makeItem(at date: Date) -> ClipboardItem {
        let payloadID = UUID()
        return ClipboardItem(
            id: UUID(),
            kind: kind,
            title: title,
            subtitle: subtitle,
            sourceAppName: sourceAppName,
            sourceBundleIdentifier: sourceBundleIdentifier,
            createdAt: date,
            capturedAt: date,
            pinnedAt: nil,
            signature: signature,
            payloadID: payloadID,
            storedByteCount: 0,
            searchText: searchText,
            ocrText: nil
        )
    }
}

struct ClipboardArchive: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion = currentSchemaVersion
    var phaseThreeActivatedAt: Date?
    var lastScreenshotScanAt: Date?
    var items: [ClipboardItem] = []
}

struct ExcludedClipboardApp: Identifiable, Codable, Equatable {
    var bundleIdentifier: String
    var displayName: String

    var id: String {
        bundleIdentifier
    }
}

struct ClipboardRetentionPolicy {
    var lifetime: TimeInterval = 7 * 24 * 60 * 60
    var maximumUnpinnedItems = 200
    var maximumUnpinnedBytes: Int64 = 1_073_741_824

    func removalIDs(from items: [ClipboardItem], now: Date) -> Set<UUID> {
        var removalIDs = Set(
            items
                .filter { !$0.isPinned && now.timeIntervalSince($0.capturedAt) >= lifetime }
                .map(\.id)
        )

        var survivors = items
            .filter { !$0.isPinned && !removalIDs.contains($0.id) }
            .sorted { $0.capturedAt < $1.capturedAt }

        while survivors.count > maximumUnpinnedItems {
            removalIDs.insert(survivors.removeFirst().id)
        }

        var byteCount = survivors.reduce(Int64(0)) { $0 + max(0, $1.storedByteCount) }
        while byteCount > maximumUnpinnedBytes, !survivors.isEmpty {
            let item = survivors.removeFirst()
            removalIDs.insert(item.id)
            byteCount -= max(0, item.storedByteCount)
        }

        return removalIDs
    }
}

extension ClipboardCapture {
    static func signature(kind: ClipboardItem.Kind, representations: [(String, Data)]) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(kind.rawValue.utf8))

        for representation in representations.sorted(by: { $0.0 < $1.0 }) {
            hasher.update(data: Data(representation.0.utf8))
            hasher.update(data: representation.1)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
