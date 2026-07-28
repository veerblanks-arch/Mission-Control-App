import AppKit
import SwiftUI

@MainActor
final class SnippetEditorWindowController: NSWindowController, NSWindowDelegate {
    private let bridge = SnippetEditorBridge()

    init(
        image: CGImage,
        onDone: @escaping (CGImage) -> Void,
        onCancel: @escaping () -> Void
    ) {
        let document = SnippetDocument(sourceImage: image)
        let hostingController = NSHostingController(
            rootView: SnippetEditorView(document: document, bridge: bridge)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Snippet"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 520)
        window.contentViewController = hostingController

        super.init(window: window)

        window.delegate = self
        bridge.onDone = { [weak self] renderedImage in
            self?.close()
            onDone(renderedImage)
        }
        bridge.onCancel = { [weak self] in
            self?.close()
            onCancel()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        bridge.onCancel?()
        bridge.onCancel = nil
        bridge.onDone = nil
    }
}

@MainActor
final class SnippetEditorBridge {
    var onDone: ((CGImage) -> Void)?
    var onCancel: (() -> Void)?

    func finish(with image: CGImage) {
        let handler = onDone
        onDone = nil
        onCancel = nil
        handler?(image)
    }

    func cancel() {
        let handler = onCancel
        onDone = nil
        onCancel = nil
        handler?()
    }
}

private struct SnippetEditorView: View {
    @ObservedObject var document: SnippetDocument
    let bridge: SnippetEditorBridge

    var body: some View {
        VStack(spacing: 0) {
            primaryToolbar
            Divider()
            canvas
            Divider()
            optionsBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand {
            bridge.cancel()
        }
    }

    private var primaryToolbar: some View {
        HStack(spacing: 6) {
            Text("Snippet")
                .font(.system(size: 15, weight: .semibold))
                .padding(.trailing, 10)

            ForEach(SnippetTool.allCases) { tool in
                Button {
                    document.selectedTool = tool
                } label: {
                    Image(systemName: tool.symbolName)
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .foregroundStyle(
                            document.selectedTool == tool
                                ? Color.accentColor
                                : Color.secondary
                        )
                        .background(
                            document.selectedTool == tool
                                ? Color.accentColor.opacity(0.14)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                }
                .buttonStyle(.plain)
                .help(tool.title)
            }

            Divider()
                .frame(height: 22)
                .padding(.horizontal, 5)

            Button {
                document.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(!document.canUndo)
            .help("Undo")

            Button {
                document.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(!document.canRedo)
            .help("Redo")

            Spacer()

            Button("Cancel") {
                bridge.cancel()
            }
            .keyboardShortcut(.cancelAction)

            Button {
                guard let image = document.renderedImage() else {
                    return
                }
                bridge.finish(with: image)
            } label: {
                Label("Done", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var canvas: some View {
        SnippetCanvasRepresentable(document: document)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var optionsBar: some View {
        HStack(spacing: 12) {
            Text("Color")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(SnippetColor.palette) { color in
                Button {
                    document.selectedColor = color
                } label: {
                    Circle()
                        .fill(Color(nsColor: color.nsColor))
                        .frame(width: 18, height: 18)
                        .overlay {
                            Circle()
                                .strokeBorder(
                                    document.selectedColor == color
                                        ? Color.accentColor
                                        : Color.primary.opacity(0.22),
                                    lineWidth: document.selectedColor == color ? 3 : 1
                                )
                        }
                        .padding(3)
                }
                .buttonStyle(.plain)
                .help(color.id.capitalized)
            }

            Divider()
                .frame(height: 24)

            Image(systemName: "line.diagonal")
                .foregroundStyle(.secondary)
                .help("Thickness")

            Slider(value: $document.thickness, in: 2...18, step: 1)
                .frame(width: 120)
                .help("Thickness")

            Text("\(Int(document.thickness))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            if document.selectedTool == .text {
                Divider()
                    .frame(height: 24)
                TextField("Annotation text", text: $document.textValue)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 150, idealWidth: 220, maxWidth: 300)
            }

            Spacer()

            if document.selectedTool == .crop {
                Text("Drag over the area to keep")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            } else if document.selectedTool == .text {
                Text("Click the image to place text")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct SnippetCanvasRepresentable: NSViewRepresentable {
    @ObservedObject var document: SnippetDocument

    func makeNSView(context: Context) -> SnippetCanvasView {
        SnippetCanvasView(document: document)
    }

    func updateNSView(_ nsView: SnippetCanvasView, context: Context) {
        nsView.document = document
        nsView.needsDisplay = true
    }
}

@MainActor
private final class SnippetCanvasView: NSView {
    private let blurredSourceImage: NSImage?

    var document: SnippetDocument {
        didSet {
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(document: SnippetDocument) {
        self.document = document
        blurredSourceImage = SnippetRenderer.makeBlurredImage(document.sourceImage)
            .map { NSImage(cgImage: $0, size: .zero) }
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()

        let imageRect = fittedImageRect
        guard imageRect.width > 0, imageRect.height > 0 else {
            return
        }

        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(
            cgImage: document.sourceImage,
            size: imageRect.size
        ).draw(in: imageRect)

        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: imageRect).addClip()
        for annotation in document.displayAnnotations {
            draw(annotation, in: imageRect)
        }
        if let cropRect = document.cropRect {
            drawCropOverlay(cropRect, in: imageRect)
        }
        NSGraphicsContext.current?.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.14).setStroke()
        let border = NSBezierPath(roundedRect: imageRect, xRadius: 3, yRadius: 3)
        border.lineWidth = 1
        border.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard let point = normalizedPoint(for: event) else {
            return
        }
        window?.makeFirstResponder(self)
        document.beginGesture(at: point)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let point = normalizedPoint(for: event) else {
            return
        }
        document.continueGesture(to: point)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let point = normalizedPoint(for: event) {
            document.continueGesture(to: point)
        }
        document.endGesture()
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" {
            if event.modifierFlags.contains(.shift) {
                document.redo()
            } else {
                document.undo()
            }
            needsDisplay = true
            return
        }
        super.keyDown(with: event)
    }

    private var fittedImageRect: CGRect {
        let available = bounds.insetBy(dx: 28, dy: 28)
        let imageSize = CGSize(
            width: document.sourceImage.width,
            height: document.sourceImage.height
        )
        guard
            available.width > 0,
            available.height > 0,
            imageSize.width > 0,
            imageSize.height > 0
        else {
            return .zero
        }

        let scale = min(
            available.width / imageSize.width,
            available.height / imageSize.height
        )
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: available.midX - size.width / 2,
            y: available.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func normalizedPoint(for event: NSEvent) -> CGPoint? {
        let point = convert(event.locationInWindow, from: nil)
        let imageRect = fittedImageRect
        guard imageRect.contains(point) else {
            return nil
        }
        return CGPoint(
            x: (point.x - imageRect.minX) / imageRect.width,
            y: (point.y - imageRect.minY) / imageRect.height
        )
    }

    private func draw(_ annotation: SnippetAnnotation, in imageRect: CGRect) {
        switch annotation {
        case let .stroke(points, color, width, opacity):
            guard let first = points.first else { return }
            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.lineWidth = width
            path.move(to: viewPoint(first, in: imageRect))
            for point in points.dropFirst() {
                path.line(to: viewPoint(point, in: imageRect))
            }
            color.nsColor.withAlphaComponent(opacity).setStroke()
            path.stroke()

        case let .arrow(start, end, color, width):
            let startPoint = viewPoint(start, in: imageRect)
            let endPoint = viewPoint(end, in: imageRect)
            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.lineWidth = width
            path.move(to: startPoint)
            path.line(to: endPoint)

            let angle = atan2(endPoint.y - startPoint.y, endPoint.x - startPoint.x)
            let headLength = max(width * 4, 14)
            for offset in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
                path.move(to: endPoint)
                path.line(
                    to: CGPoint(
                        x: endPoint.x + cos(angle + offset) * headLength,
                        y: endPoint.y + sin(angle + offset) * headLength
                    )
                )
            }
            color.nsColor.setStroke()
            path.stroke()

        case let .rectangle(rect, color, width):
            color.nsColor.setStroke()
            let path = NSBezierPath(rect: viewRect(rect, in: imageRect))
            path.lineWidth = width
            path.stroke()

        case let .text(value, origin, color):
            let point = viewPoint(origin, in: imageRect)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
                .foregroundColor: color.nsColor,
                .strokeColor: NSColor.black.withAlphaComponent(0.45),
                .strokeWidth: -1.5,
            ]
            NSAttributedString(string: value, attributes: attributes)
                .draw(at: point)

        case let .blur(rect):
            guard let blurredSourceImage else { return }
            NSGraphicsContext.current?.saveGraphicsState()
            NSBezierPath(rect: viewRect(rect, in: imageRect)).addClip()
            blurredSourceImage.draw(in: imageRect)
            NSGraphicsContext.current?.restoreGraphicsState()

        case let .redact(rect):
            let rect = viewRect(rect, in: imageRect)
            NSColor.black.setFill()
            rect.fill()
            NSColor.white.withAlphaComponent(0.18).setStroke()
            NSBezierPath(rect: rect).stroke()
        }
    }

    private func drawCropOverlay(_ normalizedRect: CGRect, in imageRect: CGRect) {
        let cropRect = viewRect(normalizedRect, in: imageRect)
        NSColor.black.withAlphaComponent(0.58).setFill()
        let shade = NSBezierPath(rect: imageRect)
        shade.append(NSBezierPath(rect: cropRect))
        shade.windingRule = .evenOdd
        shade.fill()

        NSColor.white.setStroke()
        let border = NSBezierPath(rect: cropRect)
        border.lineWidth = 2
        border.setLineDash([6, 4], count: 2, phase: 0)
        border.stroke()
    }

    private func viewPoint(_ point: CGPoint, in imageRect: CGRect) -> CGPoint {
        CGPoint(
            x: imageRect.minX + point.x * imageRect.width,
            y: imageRect.minY + point.y * imageRect.height
        )
    }

    private func viewRect(_ rect: CGRect, in imageRect: CGRect) -> CGRect {
        CGRect(
            x: imageRect.minX + rect.minX * imageRect.width,
            y: imageRect.minY + rect.minY * imageRect.height,
            width: rect.width * imageRect.width,
            height: rect.height * imageRect.height
        )
    }
}
