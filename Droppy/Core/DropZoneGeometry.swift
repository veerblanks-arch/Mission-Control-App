import AppKit

enum DropZoneGeometry {
    static let activationSize = NSSize(width: 300, height: 44)
    static let panelSize = NSSize(width: 300, height: 112)
    static let topInset: CGFloat = 6

    static func activationFrame(for screenFrame: NSRect) -> NSRect {
        NSRect(
            x: screenFrame.midX - (activationSize.width / 2),
            y: screenFrame.maxY - activationSize.height,
            width: activationSize.width,
            height: activationSize.height
        )
    }

    static func panelFrame(for screenFrame: NSRect) -> NSRect {
        NSRect(
            x: screenFrame.midX - (panelSize.width / 2),
            y: screenFrame.maxY - panelSize.height - topInset,
            width: panelSize.width,
            height: panelSize.height
        )
    }
}
