import AppKit

struct SnippetCaptureCommand {
    static func arguments(
        for mode: SnippetCaptureMode,
        displayNumber: Int,
        destinationURL: URL
    ) -> [String] {
        switch mode {
        case .region:
            return ["-i", "-s", "-x", destinationURL.path]
        case .window:
            return ["-i", "-w", "-x", destinationURL.path]
        case .fullScreen:
            return ["-x", "-D", String(max(displayNumber, 1)), destinationURL.path]
        }
    }
}

protocol SnippetCaptureRunning: AnyObject {
    func capture(
        mode: SnippetCaptureMode,
        displayNumber: Int,
        completion: @escaping (Result<URL?, Error>) -> Void
    )
}

final class SnippetCaptureRunner: SnippetCaptureRunning {
    private var process: Process?

    func capture(
        mode: SnippetCaptureMode,
        displayNumber: Int,
        completion: @escaping (Result<URL?, Error>) -> Void
    ) {
        guard process == nil else {
            completion(.failure(SnippetCaptureError.captureAlreadyRunning))
            return
        }

        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mission-Control-Snippet-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = SnippetCaptureCommand.arguments(
            for: mode,
            displayNumber: displayNumber,
            destinationURL: destinationURL
        )
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        self.process = process

        process.terminationHandler = { [weak self] process in
            let exists = FileManager.default.fileExists(atPath: destinationURL.path)
            DispatchQueue.main.async {
                self?.process = nil
                if exists {
                    completion(.success(destinationURL))
                } else if mode != .fullScreen {
                    completion(.success(nil))
                } else {
                    completion(
                        .failure(
                            SnippetCaptureError.captureFailed(
                                terminationStatus: process.terminationStatus
                            )
                        )
                    )
                }
            }
        }

        do {
            try process.run()
        } catch {
            self.process = nil
            try? FileManager.default.removeItem(at: destinationURL)
            completion(.failure(error))
        }
    }
}

struct SnippetStorage {
    private let fileManager: FileManager
    private let screenshotMonitor: ScreenshotMonitor

    init(
        fileManager: FileManager = .default,
        screenshotMonitor: ScreenshotMonitor = ScreenshotMonitor()
    ) {
        self.fileManager = fileManager
        self.screenshotMonitor = screenshotMonitor
    }

    func save(_ image: CGImage, at date: Date = Date()) throws -> URL {
        let folder = screenshotMonitor.preferredSaveFolder()
        try fileManager.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )

        let baseName = "Snippet \(Self.timestamp(for: date))"
        var destination = folder.appendingPathComponent(baseName).appendingPathExtension("png")
        var suffix = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = folder
                .appendingPathComponent("\(baseName) \(suffix)")
                .appendingPathExtension("png")
            suffix += 1
        }

        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw SnippetCaptureError.pngEncodingFailed
        }
        try data.write(to: destination, options: .atomic)
        return destination
    }

    static func timestamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        return formatter.string(from: date)
    }
}

@MainActor
final class SnippetCaptureCoordinator {
    private let clipboardManager: ClipboardManagerFeature
    private let permissionsManager: PermissionsManager
    private let runner: SnippetCaptureRunning
    private let storage: SnippetStorage
    private var editorWindowController: SnippetEditorWindowController?
    private var isCapturing = false

    init(
        clipboardManager: ClipboardManagerFeature,
        permissionsManager: PermissionsManager,
        runner: SnippetCaptureRunning = SnippetCaptureRunner(),
        storage: SnippetStorage = SnippetStorage()
    ) {
        self.clipboardManager = clipboardManager
        self.permissionsManager = permissionsManager
        self.runner = runner
        self.storage = storage
    }

    func capture(_ mode: SnippetCaptureMode) {
        guard !isCapturing, editorWindowController == nil else {
            return
        }
        guard permissionsManager.requestScreenCaptureAccessIfNeeded() else {
            showScreenRecordingPermissionError()
            return
        }

        isCapturing = true
        runner.capture(
            mode: mode,
            displayNumber: activeDisplayNumber()
        ) { [weak self] result in
            guard let self else { return }
            self.isCapturing = false

            switch result {
            case let .success(url?):
                self.openEditor(for: url)
            case .success(nil):
                break
            case let .failure(error):
                self.showError(
                    title: "Couldn’t Capture Snippet",
                    message: error.localizedDescription
                )
            }
        }
    }

#if DEBUG
    func showEditorForDebug() {
        let width = 1200
        let height = 760
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
            return
        }

        let colors = [
            NSColor(calibratedRed: 0.11, green: 0.14, blue: 0.18, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.30, green: 0.48, blue: 0.72, alpha: 1).cgColor,
        ] as CFArray
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: width, y: height),
                options: []
            )
        }

        context.setFillColor(NSColor.white.withAlphaComponent(0.88).cgColor)
        context.fill(CGRect(x: 100, y: 120, width: 430, height: 250))
        context.setFillColor(NSColor.systemPink.cgColor)
        context.fillEllipse(in: CGRect(x: 710, y: 180, width: 260, height: 260))
        guard let image = context.makeImage() else {
            return
        }
        openEditor(image: image)
    }
#endif

    private func activeDisplayNumber() -> Int {
        let mouseLocation = NSEvent.mouseLocation
        let activeScreen = NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard
            let activeScreen,
            let index = NSScreen.screens.firstIndex(of: activeScreen)
        else {
            return 1
        }
        return index + 1
    }

    private func openEditor(for temporaryURL: URL) {
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        guard
            let image = NSImage(contentsOf: temporaryURL),
            let cgImage = image.cgImage(
                forProposedRect: nil,
                context: nil,
                hints: nil
            )
        else {
            showError(
                title: "Couldn’t Open Snippet",
                message: "The captured image could not be read."
            )
            return
        }

        openEditor(image: cgImage)
    }

    private func openEditor(image cgImage: CGImage) {
        let editor = SnippetEditorWindowController(
            image: cgImage,
            onDone: { [weak self] renderedImage in
                self?.editorWindowController = nil
                self?.finish(renderedImage)
            },
            onCancel: { [weak self] in
                self?.editorWindowController = nil
            }
        )
        editorWindowController = editor
        editor.present()
    }

    private func finish(_ image: CGImage) {
        do {
            let savedURL = try storage.save(image)
            guard clipboardManager.ingestSnippet(at: savedURL) != nil else {
                throw SnippetCaptureError.clipboardInsertionFailed
            }
        } catch {
            showError(
                title: "Couldn’t Save Snippet",
                message: error.localizedDescription
            )
        }
    }

    private func showError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showScreenRecordingPermissionError() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Screen Recording Permission Needed"
        alert.informativeText =
            "Allow Mission Control in Privacy & Security > Screen Recording. After changing this permission, relaunch Mission Control and try again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            permissionsManager.openScreenRecordingSettings()
        }
    }
}

enum SnippetCaptureError: LocalizedError {
    case captureAlreadyRunning
    case captureFailed(terminationStatus: Int32)
    case pngEncodingFailed
    case clipboardInsertionFailed

    var errorDescription: String? {
        switch self {
        case .captureAlreadyRunning:
            return "Another snippet capture is already running."
        case let .captureFailed(status):
            return "The macOS capture service exited with status \(status)."
        case .pngEncodingFailed:
            return "Mission Control could not encode the annotated image as PNG."
        case .clipboardInsertionFailed:
            return "The image was saved, but Mission Control could not add it to Clipboard history."
        }
    }
}
