import AppKit
import SwiftUI

@MainActor
final class ScreenshotNotificationCoordinator {
    private let panel: NSPanel
    private let hostingController: NSHostingController<ScreenshotNotificationView>
    private let onOpenClipboard: (UUID) -> Void
    private var dismissalWorkItem: DispatchWorkItem?

    init(onOpenClipboard: @escaping (UUID) -> Void) {
        self.onOpenClipboard = onOpenClipboard

        let rootView = ScreenshotNotificationView(
            image: NSImage(),
            onOpen: {}
        )
        hostingController = NSHostingController(rootView: rootView)
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 286, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hostingController
        panel.level = .popUpMenu
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle,
        ]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
    }

    func show(item: ClipboardItem, image: NSImage) {
        dismissalWorkItem?.cancel()

        hostingController.rootView = ScreenshotNotificationView(
            image: image,
            onOpen: { [weak self] in
                self?.dismissalWorkItem?.cancel()
                self?.panel.orderOut(nil)
                self?.onOpenClipboard(item.id)
            }
        )
        positionPanel()
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                self.panel.animator().alphaValue = 0
            } completionHandler: {
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            }
        }
        dismissalWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.64, execute: workItem)
    }

    private func positionPanel() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main
        guard let screen else {
            return
        }

        let size = panel.frame.size
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.visibleFrame.maxY - size.height - 8
        )
        panel.setFrameOrigin(origin)
    }
}

private struct ScreenshotNotificationView: View {
    let image: NSImage
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 11) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Screenshot saved")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Added to Clipboard")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .frame(width: 286, height: 72)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.white.opacity(0.16), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
