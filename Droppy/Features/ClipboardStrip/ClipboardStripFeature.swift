import AppKit
import Combine

final class ClipboardManagerFeature: ObservableObject {
    static let shared = ClipboardManagerFeature()
    static let phase = 1

    @Published private(set) var items: [ClipboardItem] = []

    private let store = ClipboardHistoryStore()
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private let maxItems = 100

    private init() {
        items = store.load()
    }

    func start() {
        guard timer == nil else {
            return
        }

        captureCurrentClipboardIfNeeded()
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.captureCurrentClipboardIfNeeded()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func copy(_ item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.kind {
        case .text:
            if let text = item.text {
                pasteboard.setString(text, forType: .string)
            }
        case .file:
            let urls = item.filePaths.map { URL(fileURLWithPath: $0) } as [NSURL]
            pasteboard.writeObjects(urls)
        case .image:
            if let imageData = item.imagePNGData, let image = NSImage(data: imageData) {
                pasteboard.writeObjects([image])
            }
        }

        lastChangeCount = pasteboard.changeCount
    }

    func clearHistory() {
        items = []
        store.save(items)
    }

    private func captureCurrentClipboardIfNeeded() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else {
            return
        }

        lastChangeCount = pasteboard.changeCount

        guard let item = ClipboardItem(pasteboard: pasteboard) else {
            return
        }

        if items.first?.signature == item.signature {
            return
        }

        items.removeAll { $0.signature == item.signature }
        items.insert(item, at: 0)

        if items.count > maxItems {
            items.removeLast(items.count - maxItems)
        }

        store.save(items)
    }
}

struct ClipboardItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case text
        case image
        case file
    }

    let id: UUID
    let kind: Kind
    let title: String
    let subtitle: String
    let text: String?
    let filePaths: [String]
    let imagePNGData: Data?
    let createdAt: Date
    let sourceApp: String
    let pinned: Bool

    var signature: String {
        switch kind {
        case .text:
            return "text:\(text ?? "")"
        case .image:
            return "image:\(imagePNGData?.base64EncodedString() ?? "")"
        case .file:
            return "file:\(filePaths.joined(separator: "|"))"
        }
    }

    var formattedTime: String {
        createdAt.formatted(date: .omitted, time: .shortened)
    }

    init?(
        pasteboard: NSPasteboard,
        sourceApp: String = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown App"
    ) {
        if let fileURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !fileURLs.isEmpty {
            id = UUID()
            kind = .file
            title = fileURLs.count == 1 ? fileURLs[0].lastPathComponent : "\(fileURLs.count) files"
            subtitle = fileURLs.count == 1 ? fileURLs[0].deletingLastPathComponent().path : "Multiple file paths"
            text = nil
            filePaths = fileURLs.map(\.path)
            imagePNGData = nil
            createdAt = Date()
            self.sourceApp = sourceApp
            pinned = false
            return
        }

        if let string = pasteboard.string(forType: .string), !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            id = UUID()
            kind = .text
            title = string.singleLinePreview(limit: 80)
            subtitle = "\(string.count) characters"
            text = string
            filePaths = []
            imagePNGData = nil
            createdAt = Date()
            self.sourceApp = sourceApp
            pinned = false
            return
        }

        if let image = NSImage(pasteboard: pasteboard), let imageData = image.pngData {
            id = UUID()
            kind = .image
            title = "Image"
            subtitle = "\(Int(image.size.width)) x \(Int(image.size.height))"
            text = nil
            filePaths = []
            imagePNGData = imageData
            createdAt = Date()
            self.sourceApp = sourceApp
            pinned = false
            return
        }

        return nil
    }
}

private final class ClipboardHistoryStore {
    private let fileURL: URL

    init(fileManager: FileManager = .default) {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let folderURL = baseURL.appendingPathComponent("Droppy", isDirectory: true)
        fileURL = folderURL.appendingPathComponent("ClipboardHistory.json")

        try? fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
    }

    func load() -> [ClipboardItem] {
        guard let data = try? Data(contentsOf: fileURL) else {
            return []
        }

        return (try? JSONDecoder.droppy.decode([ClipboardItem].self, from: data)) ?? []
    }

    func save(_ items: [ClipboardItem]) {
        guard let data = try? JSONEncoder.droppy.encode(items) else {
            return
        }

        try? data.write(to: fileURL, options: [.atomic])
    }
}

private extension JSONEncoder {
    static var droppy: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var droppy: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension NSImage {
    var pngData: Data? {
        guard
            let tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffRepresentation)
        else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }
}

private extension String {
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
