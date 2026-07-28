import AppKit
import CryptoKit
import XCTest
@testable import Droppy

final class DroppyTests: XCTestCase {
    func testPanelCentersBelowAnchor() {
        let frame = PanelGeometry.anchoredFrame(
            size: NSSize(width: 420, height: 560),
            anchorFrame: NSRect(x: 900, y: 1060, width: 24, height: 24),
            visibleScreenFrame: NSRect(x: 0, y: 0, width: 1920, height: 1056)
        )

        XCTAssertEqual(frame.midX, 912, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, 1054, accuracy: 0.001)
    }

    func testPanelClampsToLeftScreenEdge() {
        let frame = PanelGeometry.anchoredFrame(
            size: NSSize(width: 420, height: 560),
            anchorFrame: NSRect(x: 4, y: 1060, width: 24, height: 24),
            visibleScreenFrame: NSRect(x: 0, y: 0, width: 1920, height: 1056)
        )

        XCTAssertEqual(frame.minX, 0, accuracy: 0.001)
    }

    func testPanelClampsToRightScreenEdgeWithOffsetDisplay() {
        let visibleFrame = NSRect(x: 1920, y: 100, width: 1440, height: 900)
        let frame = PanelGeometry.anchoredFrame(
            size: NSSize(width: 420, height: 560),
            anchorFrame: NSRect(x: 3340, y: 1004, width: 20, height: 20),
            visibleScreenFrame: visibleFrame
        )

        XCTAssertEqual(frame.maxX, visibleFrame.maxX, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(frame.minY, visibleFrame.minY)
    }

    func testPanelSizeIsClamped() {
        XCTAssertEqual(
            PanelGeometry.clampedSize(NSSize(width: 100, height: 100)),
            PanelGeometry.minimumSize
        )
        XCTAssertEqual(
            PanelGeometry.clampedSize(NSSize(width: 2000, height: 2000)),
            PanelGeometry.maximumSize
        )
    }

    func testDropZoneGeometryUsesPhysicalTopCenter() {
        let screenFrame = NSRect(x: -1440, y: 180, width: 1440, height: 900)
        let activationFrame = DropZoneGeometry.activationFrame(for: screenFrame)
        let panelFrame = DropZoneGeometry.panelFrame(for: screenFrame)

        XCTAssertEqual(activationFrame.width, 300)
        XCTAssertEqual(activationFrame.midX, screenFrame.midX, accuracy: 0.001)
        XCTAssertEqual(activationFrame.maxY, screenFrame.maxY, accuracy: 0.001)
        XCTAssertEqual(panelFrame.midX, screenFrame.midX, accuracy: 0.001)
        XCTAssertEqual(panelFrame.maxY, screenFrame.maxY - DropZoneGeometry.topInset, accuracy: 0.001)
    }

    func testShelfAddsBatchInDeterministicOrder() throws {
        let fixture = try ShelfTestFixture()
        let first = try fixture.createFile(named: "first.txt")
        let second = try fixture.createFile(named: "second.txt")
        let folder = try fixture.createFolder(named: "Folder")
        let feature = ShelfFeature(store: fixture.store)

        XCTAssertEqual(feature.add([first, second, folder], at: Date(timeIntervalSince1970: 100)), 3)
        XCTAssertEqual(feature.items.map(\.displayName), ["first.txt", "second.txt", "Folder"])
        XCTAssertEqual(feature.items.map(\.kind), [.file, .file, .folder])
    }

    func testShelfDeduplicatesNormalizedPathAndPreservesIdentity() throws {
        let fixture = try ShelfTestFixture()
        let file = try fixture.createFile(named: "same.txt")
        let feature = ShelfFeature(store: fixture.store)

        feature.add([file], at: Date(timeIntervalSince1970: 100))
        let originalID = try XCTUnwrap(feature.items.first?.id)
        feature.add(
            [file.deletingLastPathComponent().appendingPathComponent("./same.txt")],
            at: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(feature.items.count, 1)
        XCTAssertEqual(feature.items.first?.id, originalID)
        XCTAssertEqual(feature.items.first?.addedAt, Date(timeIntervalSince1970: 200))
    }

    func testShelfPersistsAcrossRelaunch() throws {
        let fixture = try ShelfTestFixture()
        let file = try fixture.createFile(named: "persisted.txt")
        let firstFeature = ShelfFeature(store: fixture.store)
        firstFeature.add([file], at: Date(timeIntervalSince1970: 100))

        let reloadedFeature = ShelfFeature(store: ShelfStore(fileURL: fixture.storeURL))

        XCTAssertEqual(reloadedFeature.items.count, 1)
        XCTAssertEqual(reloadedFeature.items.first?.displayName, "persisted.txt")
        XCTAssertEqual(
            reloadedFeature.items.first?.resolvedURL.resolvingSymlinksInPath().path,
            file.resolvingSymlinksInPath().path
        )
    }

    func testRemovingShelfReferenceDoesNotDeleteOriginal() throws {
        let fixture = try ShelfTestFixture()
        let file = try fixture.createFile(named: "keep-me.txt")
        let feature = ShelfFeature(store: fixture.store)
        feature.add([file])

        let item = try XCTUnwrap(feature.items.first)
        feature.remove(item)

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(feature.items.isEmpty)
    }

    func testMissingShelfItemRemainsVisible() throws {
        let fixture = try ShelfTestFixture()
        let file = try fixture.createFile(named: "temporary.txt")
        let feature = ShelfFeature(store: fixture.store)
        feature.add([file])
        try FileManager.default.removeItem(at: file)

        let reloadedFeature = ShelfFeature(store: ShelfStore(fileURL: fixture.storeURL))

        XCTAssertEqual(reloadedFeature.items.count, 1)
        XCTAssertFalse(try XCTUnwrap(reloadedFeature.items.first).exists)
    }

    func testShelfDragSuggestedNameLeavesExtensionForProvider() throws {
        let fixture = try ShelfTestFixture()
        let file = try fixture.createFile(named: "archive.tar.gz")
        let folder = try fixture.createFolder(named: "Folder.with.dots")

        let fileItem = ShelfItem(url: file, addedAt: Date(), order: 1)
        let folderItem = ShelfItem(url: folder, addedAt: Date(), order: 2)

        XCTAssertEqual(fileItem.dragSuggestedName, "archive.tar")
        XCTAssertEqual(folderItem.dragSuggestedName, "Folder.with.dots")
    }

    func testClipboardRetentionPreservesPinsAndRemovesExpiredItems() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let expired = clipboardItem(capturedAt: now.addingTimeInterval(-604_801))
        let recent = clipboardItem(capturedAt: now.addingTimeInterval(-60))
        let pinned = clipboardItem(
            capturedAt: now.addingTimeInterval(-700_000),
            pinnedAt: now.addingTimeInterval(-700_000)
        )

        let removals = ClipboardRetentionPolicy().removalIDs(
            from: [expired, recent, pinned],
            now: now
        )

        XCTAssertTrue(removals.contains(expired.id))
        XCTAssertFalse(removals.contains(recent.id))
        XCTAssertFalse(removals.contains(pinned.id))
    }

    func testClipboardRetentionAppliesCountAndByteCapsOldestFirst() {
        let now = Date(timeIntervalSince1970: 10_000)
        let oldest = clipboardItem(capturedAt: now.addingTimeInterval(-30), bytes: 60)
        let middle = clipboardItem(capturedAt: now.addingTimeInterval(-20), bytes: 60)
        let newest = clipboardItem(capturedAt: now.addingTimeInterval(-10), bytes: 60)
        let policy = ClipboardRetentionPolicy(
            lifetime: 1_000,
            maximumUnpinnedItems: 2,
            maximumUnpinnedBytes: 100
        )

        let removals = policy.removalIDs(from: [newest, oldest, middle], now: now)

        XCTAssertEqual(removals, Set([oldest.id, middle.id]))
    }

    func testClipboardSignatureKeepsDifferentFormattingSeparate() {
        let plain = ClipboardCapture.signature(
            kind: .text,
            representations: [("public.utf8-plain-text", Data("hello".utf8))]
        )
        let rich = ClipboardCapture.signature(
            kind: .text,
            representations: [
                ("public.utf8-plain-text", Data("hello".utf8)),
                ("public.rtf", Data("{\\rtf1 hello}".utf8)),
            ]
        )

        XCTAssertNotEqual(plain, rich)
    }

    func testClipboardEncryptionRejectsTampering() throws {
        let cryptor = AESClipboardCryptor(
            key: SymmetricKey(data: Data(repeating: 7, count: 32))
        )
        let additionalData = Data("test-context".utf8)
        var encrypted = try cryptor.seal(
            Data("private clipboard text".utf8),
            authenticating: additionalData
        )
        encrypted[encrypted.index(before: encrypted.endIndex)] ^= 0x01

        XCTAssertThrowsError(
            try cryptor.open(encrypted, authenticating: additionalData)
        )
    }

    func testClipboardRepositoryEncryptsIndexAndPayloadRoundTrip() throws {
        let fixture = try ClipboardTestFixture()
        let repository = try fixture.repository()
        let payload = ClipboardPayload.text(
            plainText: "phase-three-secret",
            rtfData: nil,
            rtfdData: nil,
            htmlData: nil
        )
        var item = clipboardItem(capturedAt: Date())
        item.storedByteCount = try repository.savePayload(payload, id: item.payloadID)
        let archive = ClipboardArchive(items: [item])

        try repository.save(archive)

        let reloadedArchive = try repository.load()
        let reloadedItem = try XCTUnwrap(reloadedArchive.items.first)
        XCTAssertEqual(reloadedArchive.items.count, 1)
        XCTAssertEqual(reloadedItem.id, item.id)
        XCTAssertEqual(
            reloadedItem.capturedAt.timeIntervalSince1970,
            item.capturedAt.timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertEqual(try repository.payload(for: item), payload)

        let indexData = try Data(
            contentsOf: fixture.rootURL.appendingPathComponent("History.enc")
        )
        let payloadData = try Data(
            contentsOf: fixture.rootURL
                .appendingPathComponent("Payloads")
                .appendingPathComponent("\(item.payloadID.uuidString).enc")
        )
        XCTAssertNil(indexData.range(of: Data("phase-three-secret".utf8)))
        XCTAssertNil(payloadData.range(of: Data("phase-three-secret".utf8)))
    }

    func testClipboardCaptureSkipsSensitivePasteboard() {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("DroppyTests-\(UUID().uuidString)")
        )
        pasteboard.declareTypes(
            [.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")],
            owner: nil
        )
        pasteboard.setString("do not store", forType: .string)

        XCTAssertNil(
            ClipboardCaptureReader.capture(
                from: pasteboard,
                sourceApplication: nil
            )
        )
    }

    func testScreenshotMonitorFindsDocumentsScreenshotsFolder() throws {
        let fixture = try ClipboardTestFixture()
        let screenshotFolder = fixture.rootURL.appendingPathComponent(
            "Screenshots",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: screenshotFolder,
            withIntermediateDirectories: true
        )
        let screenshotURL = screenshotFolder.appendingPathComponent("capture.png")
        try testPNGData().write(to: screenshotURL)

        let createdAt = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: createdAt],
            ofItemAtPath: screenshotURL.path
        )
        let monitor = ScreenshotMonitor(configuredRootURL: fixture.rootURL)

        let results = monitor.screenshots(
            createdAfter: createdAt.addingTimeInterval(-1),
            through: createdAt.addingTimeInterval(1)
        )

        XCTAssertEqual(results.map(\.standardizedFileURL), [screenshotURL.standardizedFileURL])
    }

    func testLegacyNumericDateClipboardArchiveMigrates() throws {
        let fixture = try ClipboardTestFixture()
        let repository = try fixture.repository()
        let legacyURL = fixture.rootURL.deletingLastPathComponent()
            .appendingPathComponent("clipboard_history.json")
        let now = Date()
        let legacyJSON: [[String: Any]] = [[
            "content": "legacy text",
            "date": now.timeIntervalSinceReferenceDate,
            "sourceApp": "TextEdit",
            "type": "text",
            "isConcealed": false,
        ]]
        let data = try JSONSerialization.data(withJSONObject: legacyJSON)
        try data.write(to: legacyURL)

        let captures = repository.legacyCaptures(now: now)

        XCTAssertEqual(captures.count, 1)
        XCTAssertEqual(captures.first?.payload.plainText, "legacy text")
    }

    private func clipboardItem(
        capturedAt: Date,
        pinnedAt: Date? = nil,
        bytes: Int64 = 10
    ) -> ClipboardItem {
        ClipboardItem(
            id: UUID(),
            kind: .text,
            title: "Text",
            subtitle: "4 characters",
            sourceAppName: "Tests",
            sourceBundleIdentifier: nil,
            createdAt: capturedAt,
            capturedAt: capturedAt,
            pinnedAt: pinnedAt,
            signature: UUID().uuidString,
            payloadID: UUID(),
            storedByteCount: bytes,
            searchText: "text",
            ocrText: nil
        )
    }

    private func testPNGData() throws -> Data {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        return try XCTUnwrap(image.pngData)
    }
}

private final class ShelfTestFixture {
    let rootURL: URL
    let storeURL: URL
    let store: ShelfStore

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroppyShelfTests-\(UUID().uuidString)", isDirectory: true)
        storeURL = rootURL.appendingPathComponent("Shelf.json")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        store = ShelfStore(fileURL: storeURL)
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func createFile(named name: String) throws -> URL {
        let url = rootURL.appendingPathComponent(name)
        try Data("fixture".utf8).write(to: url)
        return url
    }

    func createFolder(named name: String) throws -> URL {
        let url = rootURL.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class ClipboardTestFixture {
    let containerURL: URL
    let rootURL: URL

    init() throws {
        containerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroppyClipboardTests-\(UUID().uuidString)", isDirectory: true)
        rootURL = containerURL
            .appendingPathComponent("Droppy", isDirectory: true)
            .appendingPathComponent("Clipboard", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: containerURL)
    }

    func repository() throws -> ClipboardRepository {
        try ClipboardRepository(
            rootURL: rootURL,
            cryptor: AESClipboardCryptor(
                key: SymmetricKey(data: Data(repeating: 3, count: 32))
            )
        )
    }
}
