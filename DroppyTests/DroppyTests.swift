import AppKit
import CryptoKit
import UniformTypeIdentifiers
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

    func testAccessibilityAuthorizerChecksTrustWithoutPrompting() {
        var requestCount = 0
        let authorizer = AccessibilityPasteAuthorizer(
            isTrusted: { true },
            requestPermission: {
                requestCount += 1
                return false
            }
        )

        XCTAssertTrue(authorizer.canPostPasteEvent())
        XCTAssertTrue(authorizer.canPostPasteEvent())
        XCTAssertEqual(requestCount, 0)
    }

    func testAccessibilityAuthorizerPromptsOnlyOncePerLaunch() {
        var requestCount = 0
        let authorizer = AccessibilityPasteAuthorizer(
            isTrusted: { false },
            requestPermission: {
                requestCount += 1
                return false
            }
        )

        XCTAssertFalse(authorizer.canPostPasteEvent())
        XCTAssertFalse(authorizer.canPostPasteEvent())
        XCTAssertEqual(requestCount, 1)
    }

    @MainActor
    func testImageRestorePublishesPNGAndTIFF() throws {
        let fixture = try ClipboardTestFixture()
        let repository = try fixture.repository()
        let imageData = try testPNGData(width: 12, height: 8)
        var item = clipboardItem(capturedAt: Date())
        item.kind = .image
        item.title = "Image"
        item.storedByteCount = try repository.savePayload(
            .image(data: imageData, typeIdentifier: UTType.png.identifier),
            id: item.payloadID
        )
        try repository.save(ClipboardArchive(items: [item]))
        let manager = ClipboardManagerFeature(
            repository: repository,
            screenshotMonitor: ScreenshotMonitor(configuredRootURL: fixture.rootURL)
        )
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("DroppyImagePasteTests-\(UUID().uuidString)")
        )

        XCTAssertTrue(manager.restoreToPasteboard(item, pasteboard: pasteboard))
        XCTAssertEqual(pasteboard.data(forType: .png), imageData)
        XCTAssertNotNil(pasteboard.data(forType: .tiff))
    }

    @MainActor
    func testImageDragPublishesFileURLAndPNGData() throws {
        let fixture = try ClipboardTestFixture()
        let repository = try fixture.repository()
        let imageData = try testPNGData(width: 10, height: 6)
        var item = clipboardItem(capturedAt: Date())
        item.kind = .screenshot
        item.title = "Capture.png"
        item.storedByteCount = try repository.savePayload(
            .image(data: imageData, typeIdentifier: UTType.png.identifier),
            id: item.payloadID
        )
        try repository.save(ClipboardArchive(items: [item]))
        let manager = ClipboardManagerFeature(
            repository: repository,
            screenshotMonitor: ScreenshotMonitor(configuredRootURL: fixture.rootURL)
        )

        var dragContent: ClipboardDragContent? = manager.dragContent(for: item)
        let pasteboardItem = try XCTUnwrap(
            dragContent?.writers.first as? NSPasteboardItem
        )
        let fileURL = try XCTUnwrap(
            pasteboardItem.string(forType: .fileURL).flatMap(URL.init(string:))
        )
        defer {
            try? FileManager.default.removeItem(
                at: fileURL.deletingLastPathComponent()
            )
        }

        XCTAssertEqual(fileURL.lastPathComponent, "Capture.png")
        XCTAssertEqual(try Data(contentsOf: fileURL), imageData)
        XCTAssertEqual(pasteboardItem.data(forType: .png), imageData)
        XCTAssertNotNil(pasteboardItem.data(forType: .tiff))

        dragContent = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @MainActor
    func testImageItemProviderLoadsChatCompatibleFileRepresentation() throws {
        let fixture = try ClipboardTestFixture()
        let repository = try fixture.repository()
        let imageData = try testPNGData(width: 9, height: 7)
        var item = clipboardItem(capturedAt: Date())
        item.kind = .image
        item.title = "Chat Image"
        item.storedByteCount = try repository.savePayload(
            .image(data: imageData, typeIdentifier: UTType.png.identifier),
            id: item.payloadID
        )
        try repository.save(ClipboardArchive(items: [item]))
        let manager = ClipboardManagerFeature(
            repository: repository,
            screenshotMonitor: ScreenshotMonitor(configuredRootURL: fixture.rootURL)
        )
        let provider = manager.itemProvider(for: item)
        let loaded = expectation(description: "Chat-compatible image file loads")

        provider.loadFileRepresentation(forTypeIdentifier: UTType.png.identifier) { url, error in
            XCTAssertNil(error)
            XCTAssertEqual(url?.lastPathComponent, "Chat Image.png")
            XCTAssertEqual(url.flatMap { try? Data(contentsOf: $0) }, imageData)
            if let url {
                try? FileManager.default.removeItem(
                    at: url.deletingLastPathComponent()
                )
            }
            loaded.fulfill()
        }

        wait(for: [loaded], timeout: 2)
    }

    func testDragExportCleanupRemovesOnlyExpiredDirectories() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "DroppyDragExportTests-\(UUID().uuidString)",
                isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let now = Date()
        let currentExport = try ClipboardDragExportStore.makeExport(
            data: Data("current".utf8),
            fileName: "Current.png",
            rootURL: rootURL,
            now: now
        )
        let oldExport = try ClipboardDragExportStore.makeExport(
            data: Data("old".utf8),
            fileName: "Old.png",
            rootURL: rootURL,
            now: now.addingTimeInterval(
                -ClipboardDragExportStore.retentionDuration - 1
            )
        )

        ClipboardDragExportStore.removeExpired(in: rootURL, now: now)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: oldExport.directoryURL.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: currentExport.fileURL.path)
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

    func testSnippetCaptureCommandsMatchEachMode() {
        let destination = URL(fileURLWithPath: "/tmp/snippet.png")

        XCTAssertEqual(
            SnippetCaptureCommand.arguments(
                for: .region,
                displayNumber: 2,
                destinationURL: destination
            ),
            ["-i", "-s", "-x", "/tmp/snippet.png"]
        )
        XCTAssertEqual(
            SnippetCaptureCommand.arguments(
                for: .window,
                displayNumber: 2,
                destinationURL: destination
            ),
            ["-i", "-w", "-x", "/tmp/snippet.png"]
        )
        XCTAssertEqual(
            SnippetCaptureCommand.arguments(
                for: .fullScreen,
                displayNumber: 2,
                destinationURL: destination
            ),
            ["-x", "-D", "2", "/tmp/snippet.png"]
        )
    }

    func testSnippetStorageUsesNestedScreenshotFolderAndAvoidsCollisions() throws {
        let fixture = try ClipboardTestFixture()
        let screenshotFolder = fixture.rootURL.appendingPathComponent(
            "Screenshots",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: screenshotFolder,
            withIntermediateDirectories: true
        )
        let storage = SnippetStorage(
            screenshotMonitor: ScreenshotMonitor(configuredRootURL: fixture.rootURL)
        )
        let image = try testCGImage(width: 20, height: 12)
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        let first = try storage.save(image, at: date)
        let second = try storage.save(image, at: date)

        XCTAssertEqual(first.deletingLastPathComponent(), screenshotFolder)
        XCTAssertEqual(second.deletingLastPathComponent(), screenshotFolder)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(second.deletingPathExtension().lastPathComponent.suffix(2), " 2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    @MainActor
    func testSnippetDocumentUndoRedoAndCropRendering() throws {
        let document = SnippetDocument(
            sourceImage: try testCGImage(width: 100, height: 80)
        )
        document.selectedTool = .rectangle
        document.beginGesture(at: CGPoint(x: 0.1, y: 0.1))
        document.continueGesture(to: CGPoint(x: 0.5, y: 0.5))
        document.endGesture()

        XCTAssertEqual(document.annotations.count, 1)
        XCTAssertTrue(document.canUndo)
        document.undo()
        XCTAssertTrue(document.annotations.isEmpty)
        XCTAssertTrue(document.canRedo)
        document.redo()
        XCTAssertEqual(document.annotations.count, 1)

        document.selectedTool = .crop
        document.beginGesture(at: CGPoint(x: 0.25, y: 0.25))
        document.continueGesture(to: CGPoint(x: 0.75, y: 0.75))
        document.endGesture()

        let output = try XCTUnwrap(document.renderedImage())
        XCTAssertEqual(output.width, 50)
        XCTAssertEqual(output.height, 40)
    }

    @MainActor
    func testSnippetLongStrokeCommitsAsOneUndoStep() throws {
        let document = SnippetDocument(
            sourceImage: try testCGImage(width: 200, height: 120)
        )
        document.selectedTool = .pen
        document.beginGesture(at: CGPoint(x: 0.05, y: 0.5))
        for step in 1...100 {
            document.continueGesture(
                to: CGPoint(x: 0.05 + CGFloat(step) * 0.008, y: 0.5)
            )
        }
        document.endGesture()

        XCTAssertEqual(document.annotations.count, 1)
        document.undo()
        XCTAssertTrue(document.annotations.isEmpty)
        XCTAssertFalse(document.canUndo)
    }

    func testSnippetRedactionIsFullyOpaque() throws {
        let output = try XCTUnwrap(
            SnippetRenderer.render(
                sourceImage: testCGImage(width: 20, height: 20),
                annotations: [
                    .redact(rect: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6))
                ],
                cropRect: nil
            )
        )
        guard
            let data = output.dataProvider?.data,
            let bytes = CFDataGetBytePtr(data)
        else {
            return XCTFail("Missing rendered pixel data")
        }
        let bytesPerRow = output.bytesPerRow
        let offset = 10 * bytesPerRow + 10 * 4

        XCTAssertEqual(bytes[offset], 0)
        XCTAssertEqual(bytes[offset + 1], 0)
        XCTAssertEqual(bytes[offset + 2], 0)
        XCTAssertEqual(bytes[offset + 3], 255)
    }

    @MainActor
    func testSnippetIngestCreatesOneScreenshotClipboardItem() throws {
        let fixture = try ClipboardTestFixture()
        let repository = try fixture.repository()
        let manager = ClipboardManagerFeature(
            repository: repository,
            screenshotMonitor: ScreenshotMonitor(configuredRootURL: fixture.rootURL)
        )
        let screenshotURL = fixture.rootURL.appendingPathComponent("Snippet.png")
        try testPNGData().write(to: screenshotURL)
        var notificationCount = 0
        manager.onScreenshotCaptured = { _, _ in
            notificationCount += 1
        }

        let item = try XCTUnwrap(manager.ingestSnippet(at: screenshotURL))

        XCTAssertEqual(manager.items.count, 1)
        XCTAssertEqual(item.kind, .screenshot)
        XCTAssertEqual(item.sourceAppName, "Droppy Snippet")
        XCTAssertEqual(notificationCount, 1)
        XCTAssertEqual(manager.payload(for: item)?.screenshotOriginalPath, screenshotURL.path)
    }

    @MainActor
    func testSnippetIngestPreservesUnrelatedScreenshotBeforeCheckpoint() throws {
        let fixture = try ClipboardTestFixture()
        let screenshotFolder = fixture.rootURL.appendingPathComponent(
            "Screenshots",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: screenshotFolder,
            withIntermediateDirectories: true
        )
        let suiteName = "DroppySnippetTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = ClipboardManagerFeature(
            repository: try fixture.repository(),
            settings: Settings(defaults: defaults),
            screenshotMonitor: ScreenshotMonitor(configuredRootURL: fixture.rootURL)
        )
        manager.start()
        defer { manager.stop() }

        let firstDate = Date().addingTimeInterval(0.1)
        let unrelatedURL = screenshotFolder.appendingPathComponent("Unrelated.png")
        let snippetURL = screenshotFolder.appendingPathComponent("Snippet.png")
        try testPNGData(width: 4, height: 4).write(to: unrelatedURL)
        try testPNGData(width: 5, height: 5).write(to: snippetURL)
        try FileManager.default.setAttributes(
            [.modificationDate: firstDate],
            ofItemAtPath: unrelatedURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: firstDate.addingTimeInterval(0.1)],
            ofItemAtPath: snippetURL.path
        )
        var notificationCount = 0
        manager.onScreenshotCaptured = { _, _ in
            notificationCount += 1
        }

        XCTAssertNotNil(
            manager.ingestSnippet(
                at: snippetURL,
                date: firstDate.addingTimeInterval(0.2)
            )
        )

        XCTAssertEqual(manager.items.count, 2)
        XCTAssertEqual(
            Set(manager.items.map(\.title)),
            Set(["Unrelated.png", "Snippet.png"])
        )
        XCTAssertEqual(notificationCount, 2)
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

    private func testPNGData(width: CGFloat = 4, height: CGFloat = 4) throws -> Data {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        return try XCTUnwrap(image.pngData)
    }

    private func testCGImage(width: Int, height: Int) throws -> CGImage {
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw NSError(domain: "DroppyTests", code: 1)
        }
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
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
