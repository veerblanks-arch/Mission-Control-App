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
}
