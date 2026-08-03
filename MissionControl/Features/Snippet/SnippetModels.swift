import AppKit
import CoreImage
import CoreText

enum SnippetCaptureMode: String, CaseIterable, Identifiable {
    case region
    case window
    case fullScreen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .region:
            return "Capture Region"
        case .window:
            return "Capture Window"
        case .fullScreen:
            return "Capture Full Screen"
        }
    }

    var symbolName: String {
        switch self {
        case .region:
            return "viewfinder"
        case .window:
            return "macwindow"
        case .fullScreen:
            return "rectangle.inset.filled"
        }
    }
}

enum SnippetTool: String, CaseIterable, Identifiable {
    case pen
    case highlighter
    case arrow
    case rectangle
    case text
    case blur
    case redact
    case crop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pen: return "Pen"
        case .highlighter: return "Highlighter"
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        case .text: return "Text"
        case .blur: return "Blur"
        case .redact: return "Redact"
        case .crop: return "Crop"
        }
    }

    var symbolName: String {
        switch self {
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .text: return "textformat"
        case .blur: return "drop"
        case .redact: return "eye.slash"
        case .crop: return "crop"
        }
    }
}

struct SnippetColor: Identifiable, Equatable {
    let id: String
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    static let palette: [SnippetColor] = [
        SnippetColor(id: "red", red: 0.95, green: 0.22, blue: 0.24),
        SnippetColor(id: "orange", red: 1.00, green: 0.55, blue: 0.10),
        SnippetColor(id: "yellow", red: 1.00, green: 0.82, blue: 0.16),
        SnippetColor(id: "green", red: 0.18, green: 0.72, blue: 0.40),
        SnippetColor(id: "blue", red: 0.14, green: 0.52, blue: 0.96),
        SnippetColor(id: "white", red: 1.00, green: 1.00, blue: 1.00),
        SnippetColor(id: "black", red: 0.05, green: 0.05, blue: 0.06),
    ]
}

enum SnippetAnnotation: Equatable {
    case stroke(
        points: [CGPoint],
        color: SnippetColor,
        width: CGFloat,
        opacity: CGFloat
    )
    case arrow(
        start: CGPoint,
        end: CGPoint,
        color: SnippetColor,
        width: CGFloat
    )
    case rectangle(
        rect: CGRect,
        color: SnippetColor,
        width: CGFloat
    )
    case text(
        value: String,
        origin: CGPoint,
        color: SnippetColor
    )
    case blur(rect: CGRect)
    case redact(rect: CGRect)
}

struct SnippetSnapshot: Equatable {
    var annotations: [SnippetAnnotation]
    var cropRect: CGRect?
}

@MainActor
final class SnippetDocument: ObservableObject {
    let sourceImage: CGImage

    @Published var selectedTool: SnippetTool = .pen
    @Published var selectedColor = SnippetColor.palette[0]
    @Published var thickness: CGFloat = 5
    @Published var textValue = "Text"
    @Published private(set) var annotations: [SnippetAnnotation] = []
    @Published private(set) var cropRect: CGRect?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private var undoStack: [SnippetSnapshot] = []
    private var redoStack: [SnippetSnapshot] = []
    private var activeAnnotationIndex: Int?
    private var activeStroke: SnippetStrokeDraft?

    init(sourceImage: CGImage) {
        self.sourceImage = sourceImage
    }

    var displayAnnotations: [SnippetAnnotation] {
        guard let activeStroke else {
            return annotations
        }
        return annotations + [activeStroke.annotation]
    }

    func beginGesture(at point: CGPoint) {
        let point = point.clampedToUnitSquare
        recordUndoPoint()

        switch selectedTool {
        case .pen:
            activeStroke = SnippetStrokeDraft(
                points: [point],
                color: selectedColor,
                width: thickness,
                opacity: 1
            )
            activeAnnotationIndex = nil
        case .highlighter:
            activeStroke = SnippetStrokeDraft(
                points: [point],
                color: selectedColor,
                width: max(thickness * 2.5, 10),
                opacity: 0.34
            )
            activeAnnotationIndex = nil
        case .arrow:
            annotations.append(
                .arrow(
                    start: point,
                    end: point,
                    color: selectedColor,
                    width: thickness
                )
            )
            activeAnnotationIndex = annotations.indices.last
        case .rectangle:
            annotations.append(
                .rectangle(
                    rect: CGRect(origin: point, size: .zero),
                    color: selectedColor,
                    width: thickness
                )
            )
            activeAnnotationIndex = annotations.indices.last
        case .text:
            let value = textValue.trimmingCharacters(in: .whitespacesAndNewlines)
            annotations.append(
                .text(
                    value: value.isEmpty ? "Text" : value,
                    origin: point,
                    color: selectedColor
                )
            )
            activeAnnotationIndex = nil
        case .blur:
            annotations.append(.blur(rect: CGRect(origin: point, size: .zero)))
            activeAnnotationIndex = annotations.indices.last
        case .redact:
            annotations.append(.redact(rect: CGRect(origin: point, size: .zero)))
            activeAnnotationIndex = annotations.indices.last
        case .crop:
            cropRect = CGRect(origin: point, size: .zero)
            activeAnnotationIndex = nil
        }

        refreshHistoryFlags()
    }

    func continueGesture(to point: CGPoint) {
        let point = point.clampedToUnitSquare

        if let activeStroke {
            guard
                let last = activeStroke.points.last,
                hypot(point.x - last.x, point.y - last.y) >= 0.0015
            else {
                return
            }
            activeStroke.points.append(point)
            return
        }

        if selectedTool == .crop {
            guard let cropRect else { return }
            self.cropRect = CGRect.normalized(from: cropRect.origin, to: point)
            return
        }

        guard let index = activeAnnotationIndex, annotations.indices.contains(index) else {
            return
        }

        switch annotations[index] {
        case let .stroke(points, color, width, opacity):
            annotations[index] = .stroke(
                points: points + [point],
                color: color,
                width: width,
                opacity: opacity
            )
        case let .arrow(start, _, color, width):
            annotations[index] = .arrow(
                start: start,
                end: point,
                color: color,
                width: width
            )
        case let .rectangle(rect, color, width):
            annotations[index] = .rectangle(
                rect: CGRect.normalized(from: rect.origin, to: point),
                color: color,
                width: width
            )
        case let .redact(rect):
            annotations[index] = .redact(
                rect: CGRect.normalized(from: rect.origin, to: point)
            )
        case let .blur(rect):
            annotations[index] = .blur(
                rect: CGRect.normalized(from: rect.origin, to: point)
            )
        case .text:
            break
        }
    }

    func endGesture() {
        if let activeStroke {
            annotations.append(activeStroke.annotation)
            self.activeStroke = nil
        }
        activeAnnotationIndex = nil
        if let cropRect, cropRect.width < 0.01 || cropRect.height < 0.01 {
            self.cropRect = nil
        }
        refreshHistoryFlags()
    }

    func undo() {
        guard let previous = undoStack.popLast() else {
            return
        }
        redoStack.append(snapshot)
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else {
            return
        }
        undoStack.append(snapshot)
        restore(next)
    }

    func renderedImage() -> CGImage? {
        SnippetRenderer.render(
            sourceImage: sourceImage,
            annotations: annotations,
            cropRect: cropRect
        )
    }

    private var snapshot: SnippetSnapshot {
        SnippetSnapshot(annotations: annotations, cropRect: cropRect)
    }

    private func recordUndoPoint() {
        undoStack.append(snapshot)
        redoStack.removeAll()
        if undoStack.count > 100 {
            undoStack.removeFirst(undoStack.count - 100)
        }
    }

    private func restore(_ snapshot: SnippetSnapshot) {
        annotations = snapshot.annotations
        cropRect = snapshot.cropRect
        activeAnnotationIndex = nil
        activeStroke = nil
        refreshHistoryFlags()
    }

    private func refreshHistoryFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }
}

enum SnippetRenderer {
    private static let ciContext = CIContext(options: [.cacheIntermediates: true])

    static func render(
        sourceImage: CGImage,
        annotations: [SnippetAnnotation],
        cropRect normalizedCropRect: CGRect?
    ) -> CGImage? {
        let sourceSize = CGSize(
            width: sourceImage.width,
            height: sourceImage.height
        )
        let cropRect = pixelRect(
            normalizedCropRect ?? CGRect(x: 0, y: 0, width: 1, height: 1),
            in: sourceSize
        ).integral.intersection(CGRect(origin: .zero, size: sourceSize))
        guard cropRect.width > 0, cropRect.height > 0 else {
            return nil
        }

        let outputWidth = max(Int(cropRect.width), 1)
        let outputHeight = max(Int(cropRect.height), 1)
        guard
            let context = CGContext(
                data: nil,
                width: outputWidth,
                height: outputHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }

        context.translateBy(x: -cropRect.minX, y: cropRect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(sourceImage, in: CGRect(origin: .zero, size: sourceSize))

        let blurredImage = annotations.contains {
            if case .blur = $0 { return true }
            return false
        } ? makeBlurredImage(sourceImage) : nil

        for annotation in annotations {
            draw(
                annotation,
                in: context,
                imageSize: sourceSize,
                blurredImage: blurredImage
            )
        }

        return context.makeImage()
    }

    private static func draw(
        _ annotation: SnippetAnnotation,
        in context: CGContext,
        imageSize: CGSize,
        blurredImage: CGImage?
    ) {
        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch annotation {
        case let .stroke(points, color, width, opacity):
            guard let first = points.first else { break }
            context.setStrokeColor(color.nsColor.withAlphaComponent(opacity).cgColor)
            context.setLineWidth(scaledWidth(width, imageSize: imageSize))
            context.beginPath()
            context.move(to: pixelPoint(first, in: imageSize))
            for point in points.dropFirst() {
                context.addLine(to: pixelPoint(point, in: imageSize))
            }
            context.strokePath()

        case let .arrow(start, end, color, width):
            let startPoint = pixelPoint(start, in: imageSize)
            let endPoint = pixelPoint(end, in: imageSize)
            let lineWidth = scaledWidth(width, imageSize: imageSize)
            context.setStrokeColor(color.nsColor.cgColor)
            context.setLineWidth(lineWidth)
            context.beginPath()
            context.move(to: startPoint)
            context.addLine(to: endPoint)

            let angle = atan2(endPoint.y - startPoint.y, endPoint.x - startPoint.x)
            let headLength = max(lineWidth * 4, 14)
            for offset in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
                context.move(to: endPoint)
                context.addLine(
                    to: CGPoint(
                        x: endPoint.x + cos(angle + offset) * headLength,
                        y: endPoint.y + sin(angle + offset) * headLength
                    )
                )
            }
            context.strokePath()

        case let .rectangle(rect, color, width):
            context.setStrokeColor(color.nsColor.cgColor)
            context.setLineWidth(scaledWidth(width, imageSize: imageSize))
            context.stroke(pixelRect(rect, in: imageSize))

        case let .text(value, origin, color):
            let fontSize = max(min(imageSize.width, imageSize.height) * 0.035, 18)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: color.nsColor,
                .strokeColor: NSColor.black.withAlphaComponent(0.45),
                .strokeWidth: -1.5,
            ]
            let attributedString = NSAttributedString(string: value, attributes: attributes)
            let line = CTLineCreateWithAttributedString(attributedString)
            let point = pixelPoint(origin, in: imageSize)
            context.saveGState()
            context.translateBy(x: point.x, y: point.y + fontSize)
            context.scaleBy(x: 1, y: -1)
            CTLineDraw(line, context)
            context.restoreGState()

        case let .blur(rect):
            guard let blurredImage else { break }
            let pixelRect = pixelRect(rect, in: imageSize)
            context.clip(to: pixelRect)
            context.draw(blurredImage, in: CGRect(origin: .zero, size: imageSize))

        case let .redact(rect):
            let pixelRect = pixelRect(rect, in: imageSize)
            context.setFillColor(NSColor.black.cgColor)
            context.fill(pixelRect)
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
            context.setLineWidth(1)
            context.stroke(pixelRect)
        }

        context.restoreGState()
    }

    static func makeBlurredImage(_ sourceImage: CGImage) -> CGImage? {
        let source = CIImage(cgImage: sourceImage)
        guard
            let filter = CIFilter(name: "CIGaussianBlur", parameters: [
                kCIInputImageKey: source,
                kCIInputRadiusKey: 14,
            ]),
            let output = filter.outputImage?.cropped(to: source.extent)
        else {
            return nil
        }
        return ciContext.createCGImage(output, from: source.extent)
    }

    private static func pixelPoint(_ point: CGPoint, in imageSize: CGSize) -> CGPoint {
        CGPoint(x: point.x * imageSize.width, y: point.y * imageSize.height)
    }

    private static func pixelRect(_ rect: CGRect, in imageSize: CGSize) -> CGRect {
        CGRect(
            x: rect.minX * imageSize.width,
            y: rect.minY * imageSize.height,
            width: rect.width * imageSize.width,
            height: rect.height * imageSize.height
        )
    }

    private static func scaledWidth(_ width: CGFloat, imageSize: CGSize) -> CGFloat {
        width * max(min(imageSize.width, imageSize.height) / 700, 1)
    }
}

private final class SnippetStrokeDraft {
    var points: [CGPoint]
    let color: SnippetColor
    let width: CGFloat
    let opacity: CGFloat

    init(
        points: [CGPoint],
        color: SnippetColor,
        width: CGFloat,
        opacity: CGFloat
    ) {
        self.points = points
        self.color = color
        self.width = width
        self.opacity = opacity
    }

    var annotation: SnippetAnnotation {
        .stroke(
            points: points,
            color: color,
            width: width,
            opacity: opacity
        )
    }
}

extension CGRect {
    static func normalized(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }
}

private extension CGPoint {
    var clampedToUnitSquare: CGPoint {
        CGPoint(
            x: min(max(x, 0), 1),
            y: min(max(y, 0), 1)
        )
    }
}
