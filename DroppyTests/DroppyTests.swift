import AppKit
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
