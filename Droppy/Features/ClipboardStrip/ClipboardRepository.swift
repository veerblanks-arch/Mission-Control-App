import Foundation

final class ClipboardRepository {
    private let fileManager: FileManager
    private let rootURL: URL
    private let payloadsURL: URL
    private let indexURL: URL
    private let cryptor: any ClipboardCrypting

    init(
        fileManager: FileManager = .default,
        rootURL: URL? = nil,
        cryptor: (any ClipboardCrypting)? = nil
    ) throws {
        self.fileManager = fileManager

        let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.rootURL = rootURL
            ?? applicationSupportURL
                .appendingPathComponent("Droppy", isDirectory: true)
                .appendingPathComponent("Clipboard", isDirectory: true)
        payloadsURL = self.rootURL.appendingPathComponent("Payloads", isDirectory: true)
        indexURL = self.rootURL.appendingPathComponent("History.enc")

        try fileManager.createDirectory(at: payloadsURL, withIntermediateDirectories: true)

        if let cryptor {
            self.cryptor = cryptor
        } else {
            let key = try KeychainClipboardKeyStore().loadOrCreateKey(
                historyExists: fileManager.fileExists(atPath: indexURL.path)
            )
            self.cryptor = AESClipboardCryptor(key: key)
        }
    }

    func load() throws -> ClipboardArchive {
        guard fileManager.fileExists(atPath: indexURL.path) else {
            return ClipboardArchive()
        }

        do {
            let encryptedData = try Data(contentsOf: indexURL)
            let data = try cryptor.open(encryptedData, authenticating: Self.indexAdditionalData)
            let archive = try JSONDecoder.clipboard.decode(ClipboardArchive.self, from: data)
            guard archive.schemaVersion == ClipboardArchive.currentSchemaVersion else {
                throw ClipboardStorageError.invalidEncryptedData
            }
            removeOrphanedPayloads(referencedBy: archive.items)
            return archive
        } catch let error as ClipboardStorageError {
            throw error
        } catch {
            throw ClipboardStorageError.invalidEncryptedData
        }
    }

    func save(_ archive: ClipboardArchive) throws {
        let data = try JSONEncoder.clipboard.encode(archive)
        let encryptedData = try cryptor.seal(data, authenticating: Self.indexAdditionalData)
        try encryptedData.write(to: indexURL, options: [.atomic])
    }

    func savePayload(_ payload: ClipboardPayload, id: UUID) throws -> Int64 {
        let data = try JSONEncoder.clipboard.encode(payload)
        let encryptedData = try cryptor.seal(
            data,
            authenticating: Self.payloadAdditionalData(for: id)
        )
        try encryptedData.write(to: payloadURL(for: id), options: [.atomic])
        return Int64(encryptedData.count)
    }

    func payload(for item: ClipboardItem) throws -> ClipboardPayload {
        do {
            let encryptedData = try Data(contentsOf: payloadURL(for: item.payloadID))
            let data = try cryptor.open(
                encryptedData,
                authenticating: Self.payloadAdditionalData(for: item.payloadID)
            )
            return try JSONDecoder.clipboard.decode(ClipboardPayload.self, from: data)
        } catch let error as ClipboardStorageError {
            throw error
        } catch {
            throw ClipboardStorageError.invalidEncryptedData
        }
    }

    func removePayloads(for items: [ClipboardItem]) {
        for item in items {
            try? fileManager.removeItem(at: payloadURL(for: item.payloadID))
        }
    }

    func legacyCaptures(now: Date) -> [ClipboardCapture] {
        let sevenDaysAgo = now.addingTimeInterval(-7 * 24 * 60 * 60)
        var captures: [ClipboardCapture] = []

        let currentURL = rootURL.deletingLastPathComponent()
            .appendingPathComponent("ClipboardHistory.json")
        if
            let data = try? Data(contentsOf: currentURL),
            let items = try? JSONDecoder.clipboard.decode([LegacyCurrentItem].self, from: data)
        {
            captures.append(contentsOf: items.compactMap { item in
                guard item.createdAt >= sevenDaysAgo, item.sourceApp != "Screenshot" else {
                    return nil
                }
                return item.capture
            })
        }

        for filename in ["clipboard_history.json", "clipboard_history.backup.json"] {
            let url = rootURL.deletingLastPathComponent().appendingPathComponent(filename)
            guard
                let data = try? Data(contentsOf: url),
                let items = try? JSONDecoder.legacyClipboard.decode(
                    [LegacyOlderItem].self,
                    from: data
                )
            else {
                continue
            }

            captures.append(contentsOf: items.compactMap { item in
                guard item.date >= sevenDaysAgo, item.sourceApp != "Screenshot" else {
                    return nil
                }
                return item.capture
            })
        }

        var seen = Set<String>()
        return captures.filter { seen.insert($0.signature).inserted }
    }

    func removeLegacyArchives() {
        let parent = rootURL.deletingLastPathComponent()
        for filename in [
            "ClipboardHistory.json",
            "clipboard_history.json",
            "clipboard_history.backup.json",
        ] {
            try? fileManager.removeItem(at: parent.appendingPathComponent(filename))
        }
    }

    private func payloadURL(for id: UUID) -> URL {
        payloadsURL.appendingPathComponent("\(id.uuidString).enc")
    }

    private func removeOrphanedPayloads(referencedBy items: [ClipboardItem]) {
        let referencedNames = Set(items.map { "\($0.payloadID.uuidString).enc" })
        guard let urls = try? fileManager.contentsOfDirectory(
            at: payloadsURL,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        for url in urls where !referencedNames.contains(url.lastPathComponent) {
            try? fileManager.removeItem(at: url)
        }
    }

    private static let indexAdditionalData = Data("droppy.clipboard.index.v1".utf8)

    private static func payloadAdditionalData(for id: UUID) -> Data {
        Data("droppy.clipboard.payload.v1.\(id.uuidString)".utf8)
    }
}

private struct LegacyCurrentItem: Codable {
    var kind: ClipboardItem.Kind
    var title: String
    var subtitle: String
    var text: String?
    var filePaths: [String]
    var imagePNGData: Data?
    var createdAt: Date
    var sourceApp: String

    var capture: ClipboardCapture? {
        switch kind {
        case .text:
            guard let text else { return nil }
            let payload = ClipboardPayload.text(
                plainText: text,
                rtfData: nil,
                rtfdData: nil,
                htmlData: nil
            )
            return ClipboardCapture(
                kind: .text,
                title: title,
                subtitle: subtitle,
                sourceAppName: sourceApp,
                sourceBundleIdentifier: nil,
                payload: payload,
                signature: ClipboardCapture.signature(
                    kind: .text,
                    representations: [("public.utf8-plain-text", Data(text.utf8))]
                ),
                searchText: text
            )
        case .file:
            let references = filePaths.map {
                ClipboardFileReference(url: URL(fileURLWithPath: $0))
            }
            guard !references.isEmpty else { return nil }
            let payload = ClipboardPayload.files(references)
            return ClipboardCapture(
                kind: .file,
                title: title,
                subtitle: subtitle,
                sourceAppName: sourceApp,
                sourceBundleIdentifier: nil,
                payload: payload,
                signature: ClipboardCapture.signature(
                    kind: .file,
                    representations: references.map {
                        ("public.file-url", Data($0.lastKnownPath.utf8))
                    }
                ),
                searchText: references.map(\.lastKnownPath).joined(separator: "\n")
            )
        case .image:
            guard let imagePNGData else { return nil }
            let payload = ClipboardPayload.image(
                data: imagePNGData,
                typeIdentifier: "public.png"
            )
            return ClipboardCapture(
                kind: .image,
                title: title,
                subtitle: subtitle,
                sourceAppName: sourceApp,
                sourceBundleIdentifier: nil,
                payload: payload,
                signature: ClipboardCapture.signature(
                    kind: .image,
                    representations: [("public.png", imagePNGData)]
                ),
                searchText: ""
            )
        case .screenshot:
            return nil
        }
    }
}

private struct LegacyOlderItem: Codable {
    var content: String
    var date: Date
    var sourceApp: String
    var type: String
    var isConcealed: Bool

    var capture: ClipboardCapture? {
        guard type == "text", !isConcealed else {
            return nil
        }

        return ClipboardCapture(
            kind: .text,
            title: content.singleLinePreview(limit: 80),
            subtitle: "\(content.count) characters",
            sourceAppName: sourceApp,
            sourceBundleIdentifier: nil,
            payload: .text(
                plainText: content,
                rtfData: nil,
                rtfdData: nil,
                htmlData: nil
            ),
            signature: ClipboardCapture.signature(
                kind: .text,
                representations: [("public.utf8-plain-text", Data(content.utf8))]
            ),
            searchText: content
        )
    }
}

extension JSONEncoder {
    static var clipboard: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ClipboardDateCoding.precise.string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var clipboard: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = ClipboardDateCoding.precise.date(from: value)
                ?? ClipboardDateCoding.compatible.date(from: value)
            {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO 8601 clipboard date."
            )
        }
        return decoder
    }

    static var legacyClipboard: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return decoder
    }
}

private enum ClipboardDateCoding {
    static let precise: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        return formatter
    }()

    static let compatible: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

extension String {
    func singleLinePreview(limit: Int) -> String {
        let normalized = replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard normalized.count > limit else {
            return normalized
        }

        return "\(normalized.prefix(limit))..."
    }
}
