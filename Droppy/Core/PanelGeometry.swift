import AppKit

struct PanelGeometry {
    static let minimumSize = NSSize(width: 360, height: 420)
    static let defaultSize = NSSize(width: 420, height: 560)
    static let maximumSize = NSSize(width: 720, height: 760)

    static func clampedSize(_ size: NSSize) -> NSSize {
        NSSize(
            width: min(max(size.width, minimumSize.width), maximumSize.width),
            height: min(max(size.height, minimumSize.height), maximumSize.height)
        )
    }

    static func anchoredFrame(
        size requestedSize: NSSize,
        anchorFrame: NSRect,
        visibleScreenFrame: NSRect,
        gap: CGFloat = 6
    ) -> NSRect {
        let size = clampedSize(requestedSize)
        let proposedX = anchorFrame.midX - size.width / 2
        let maximumX = visibleScreenFrame.maxX - size.width
        let x = min(max(proposedX, visibleScreenFrame.minX), maximumX)
        let proposedY = anchorFrame.minY - gap - size.height
        let y = max(proposedY, visibleScreenFrame.minY)

        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }
}
