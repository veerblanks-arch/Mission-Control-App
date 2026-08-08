import AppKit
import Combine
import Foundation

enum MediaCommand: Equatable {
    case togglePlayPause
    case previous
    case next
    case seek(TimeInterval)
}

enum MediaIssueKind: Equatable {
    case applicationNotRunning
    case nothingPlaying
    case permissionDenied
    case automationFailed
    case invalidResponse
}

struct MediaIssue: Error, Equatable {
    let kind: MediaIssueKind
    let title: String
    let message: String

    static let applicationNotRunning = MediaIssue(
        kind: .applicationNotRunning,
        title: "Apple Music is not open",
        message: "Open Apple Music, start a track, then try again."
    )

    static let nothingPlaying = MediaIssue(
        kind: .nothingPlaying,
        title: "Nothing is playing",
        message: "Start a track in Apple Music, then try again."
    )

    static let invalidResponse = MediaIssue(
        kind: .invalidResponse,
        title: "Could not read Apple Music",
        message: "Apple Music returned an unexpected response. Try again."
    )

    static func automationFailure(
        status: Int32,
        errorOutput: String
    ) -> MediaIssue {
        let normalizedError = errorOutput.lowercased()
        let isPermissionError = normalizedError.contains("-1743")
            || normalizedError.contains("not authorized")
            || normalizedError.contains("not permitted")
            || normalizedError.contains("automation permission")

        if isPermissionError {
            return MediaIssue(
                kind: .permissionDenied,
                title: "Automation permission is required",
                message:
                    "Allow Mission Control to control Apple Music in System Settings > Privacy & Security > Automation."
            )
        }

        let detail = errorOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return MediaIssue(
            kind: .automationFailed,
            title: "Apple Music could not be controlled",
            message: detail.isEmpty
                ? "AppleScript exited with status \(status). Try again."
                : detail
        )
    }
}

struct MediaSnapshot {
    let title: String
    let artist: String
    let artwork: NSImage?
    let elapsedTime: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool

    var progress: Double {
        guard duration > 0 else {
            return 0
        }
        return max(0, min(1, elapsedTime / duration))
    }

    var tintColor: NSColor {
        Self.tintColor(from: artwork)
    }

    func replacing(elapsedTime: TimeInterval) -> MediaSnapshot {
        MediaSnapshot(
            title: title,
            artist: artist,
            artwork: artwork,
            elapsedTime: max(0, min(duration, elapsedTime)),
            duration: duration,
            isPlaying: isPlaying
        )
    }

    private static func tintColor(
        from artwork: NSImage?
    ) -> NSColor {
        guard
            let artwork,
            let cgImage = artwork.cgImage(
                forProposedRect: nil,
                context: nil,
                hints: nil
            )
        else {
            return .systemPink
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let width = max(1, bitmap.pixelsWide)
        let height = max(1, bitmap.pixelsHigh)
        let stepX = max(1, width / 20)
        let stepY = max(1, height / 20)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var weight: CGFloat = 0

        for y in stride(from: 0, to: height, by: stepY) {
            for x in stride(from: 0, to: width, by: stepX) {
                guard
                    let color = bitmap.colorAt(x: x, y: y)?
                        .usingColorSpace(.sRGB),
                    color.alphaComponent > 0.2
                else {
                    continue
                }
                red += color.redComponent * color.alphaComponent
                green += color.greenComponent * color.alphaComponent
                blue += color.blueComponent * color.alphaComponent
                weight += color.alphaComponent
            }
        }

        guard weight > 0 else {
            return .systemPink
        }
        let average = NSColor(
            calibratedRed: red / weight,
            green: green / weight,
            blue: blue / weight,
            alpha: 1
        )
        guard let rgb = average.usingColorSpace(.sRGB) else {
            return average
        }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getHue(
            &hue,
            saturation: &saturation,
            brightness: &brightness,
            alpha: &alpha
        )
        return NSColor(
            calibratedHue: hue,
            saturation: max(0.34, min(1, saturation * 1.12)),
            brightness: max(0.46, min(0.94, brightness * 1.04)),
            alpha: 1
        )
    }
}

enum MediaDisplayState {
    case idle
    case loading
    case ready(MediaSnapshot)
    case unavailable(MediaIssue)
    case failed(MediaIssue)

    var snapshot: MediaSnapshot? {
        guard case let .ready(snapshot) = self else {
            return nil
        }
        return snapshot
    }
}

final class MediaCancellation {
    private let lock = NSLock()
    private var isCancelledStorage = false
    private var actions: [() -> Void] = []

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelledStorage
    }

    func add(_ action: @escaping () -> Void) {
        lock.lock()
        if isCancelledStorage {
            lock.unlock()
            action()
        } else {
            actions.append(action)
            lock.unlock()
        }
    }

    func cancel() {
        lock.lock()
        guard !isCancelledStorage else {
            lock.unlock()
            return
        }
        isCancelledStorage = true
        let pendingActions = actions
        actions.removeAll()
        lock.unlock()
        pendingActions.forEach { $0() }
    }
}

protocol MediaClientProtocol {
    @discardableResult
    func fetch(
        completion: @escaping (Result<MediaSnapshot, MediaIssue>) -> Void
    ) -> MediaCancellation

    @discardableResult
    func perform(
        command: MediaCommand,
        completion: @escaping (Result<Void, MediaIssue>) -> Void
    ) -> MediaCancellation
}

@MainActor
final class MediaFeature: ObservableObject {
    static let shared = MediaFeature()

    @Published private(set) var displayState: MediaDisplayState = .idle
    @Published private(set) var controlMessage: String?

    private let client: MediaClientProtocol
    private var refreshTimer: Timer?
    private var currentRequest: MediaCancellation?
    private var controlRequest: MediaCancellation?
    private var seekWorkItem: DispatchWorkItem?
    private var pendingControlRefreshWorkItem: DispatchWorkItem?
    private var requestID = UUID()
    private var isActive = false
    private var lifecycleGeneration = UUID()

    init(client: MediaClientProtocol = LocalMediaClient()) {
        self.client = client
    }

    func start() {
        guard !isActive else {
            return
        }
        isActive = true
        lifecycleGeneration = UUID()
        refresh()
        let refreshTick = makeRefreshTimerTick()
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: 2,
            repeats: true
        ) { _ in
            Task { @MainActor in
                refreshTick()
            }
        }
    }

    func makeRefreshTimerTick() -> () -> Void {
        let activeGeneration = lifecycleGeneration
        return { [weak self] in
            guard
                let self,
                self.isActive,
                self.lifecycleGeneration == activeGeneration
            else {
                return
            }
            self.refresh(quietly: true)
        }
    }

    func stop() {
        isActive = false
        lifecycleGeneration = UUID()
        refreshTimer?.invalidate()
        refreshTimer = nil
        currentRequest?.cancel()
        currentRequest = nil
        controlRequest?.cancel()
        controlRequest = nil
        seekWorkItem?.cancel()
        seekWorkItem = nil
        pendingControlRefreshWorkItem?.cancel()
        pendingControlRefreshWorkItem = nil
    }

    func refresh(quietly: Bool = false) {
        if quietly, currentRequest != nil {
            return
        }
        currentRequest?.cancel()
        requestID = UUID()
        let activeRequestID = requestID
        if !quietly || displayState.snapshot == nil {
            displayState = .loading
        }

        currentRequest = client.fetch { [weak self] result in
            Task { @MainActor in
                guard
                    let self,
                    self.requestID == activeRequestID
                else {
                    return
                }
                self.currentRequest = nil
                switch result {
                case let .success(snapshot):
                    self.displayState = .ready(snapshot)
                    self.controlMessage = nil
                case let .failure(issue):
                    if issue.kind == .applicationNotRunning
                        || issue.kind == .nothingPlaying
                    {
                        self.displayState = .unavailable(issue)
                    } else {
                        self.displayState = .failed(issue)
                    }
                }
            }
        }
    }

    func togglePlayPause() {
        perform(.togglePlayPause)
    }

    func previousTrack() {
        perform(.previous)
    }

    func nextTrack() {
        perform(.next)
    }

    func seek(toProgress progress: Double) {
        guard let snapshot = displayState.snapshot, snapshot.duration > 0 else {
            return
        }
        let elapsedTime = max(0, min(1, progress)) * snapshot.duration
        displayState = .ready(snapshot.replacing(elapsedTime: elapsedTime))
        seekWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.perform(.seek(elapsedTime), refreshAfterward: false)
            }
        }
        seekWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.14,
            execute: workItem
        )
    }

    func openMusicApplication() {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Music"
        ) else {
            controlMessage = "Apple Music is not installed."
            return
        }
        NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { [weak self] _, error in
            guard let error else {
                return
            }
            Task { @MainActor in
                self?.controlMessage = error.localizedDescription
            }
        }
    }

    private func perform(
        _ command: MediaCommand,
        refreshAfterward: Bool = true
    ) {
        controlRequest?.cancel()
        pendingControlRefreshWorkItem?.cancel()
        pendingControlRefreshWorkItem = nil
        let controlGeneration = lifecycleGeneration
        controlRequest = client.perform(
            command: command
        ) { [weak self] result in
            Task { @MainActor in
                guard let self else {
                    return
                }
                self.controlRequest = nil
                switch result {
                case .success:
                    self.controlMessage = nil
                    if refreshAfterward {
                        let workItem = DispatchWorkItem { [weak self] in
                            Task { @MainActor in
                                guard
                                    let self,
                                    self.isActive,
                                    self.lifecycleGeneration
                                        == controlGeneration
                                else {
                                    return
                                }
                                self.pendingControlRefreshWorkItem = nil
                                self.refresh(quietly: true)
                            }
                        }
                        self.pendingControlRefreshWorkItem = workItem
                        DispatchQueue.main.asyncAfter(
                            deadline: .now() + 0.3,
                            execute: workItem
                        )
                    }
                case let .failure(issue):
                    self.controlMessage = issue.message
                }
            }
        }
    }
}

enum MediaMetadataParser {
    static let delimiter = "|||DROPPY_MEDIA|||"
    static let stoppedMarker = "__DROPPY_STOPPED__"

    static func parse(_ output: String) -> Result<ParsedMediaMetadata, MediaIssue> {
        let normalized = output.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if normalized.isEmpty || normalized == stoppedMarker {
            return .failure(.nothingPlaying)
        }

        let parts = normalized.components(separatedBy: delimiter)
        guard parts.count >= 6 else {
            return .failure(.invalidResponse)
        }
        let title = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
        let album = parts[3].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || !artist.isEmpty else {
            return .failure(.nothingPlaying)
        }

        let duration = Double(parts[4]) ?? 0
        let elapsedTime = Double(parts[5]) ?? 0
        return .success(
            ParsedMediaMetadata(
                title: title,
                artist: artist,
                album: album,
                elapsedTime: max(0, min(duration, elapsedTime)),
                duration: max(0, duration),
                isPlaying: parts[0].lowercased() == "playing"
            )
        )
    }
}

struct ParsedMediaMetadata {
    let title: String
    let artist: String
    let album: String
    let elapsedTime: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool

    func snapshot(artwork: NSImage?) -> MediaSnapshot {
        MediaSnapshot(
            title: title,
            artist: artist,
            artwork: artwork,
            elapsedTime: elapsedTime,
            duration: duration,
            isPlaying: isPlaying
        )
    }
}

final class LocalMediaClient: MediaClientProtocol {
    private static let musicBundleIdentifier = "com.apple.Music"

    private struct ProcessResult {
        let status: Int32
        let output: String
        let errorOutput: String
    }

    private let queue = DispatchQueue(
        label: "com.ranveer.droppy.media.automation",
        qos: .utility
    )
    private let isApplicationRunning: () -> Bool
    private let musicArtworkCache = NSCache<NSString, NSImage>()

    init(
        isApplicationRunning: @escaping () -> Bool = {
            !NSRunningApplication.runningApplications(
                withBundleIdentifier: LocalMediaClient.musicBundleIdentifier
            ).isEmpty
        }
    ) {
        self.isApplicationRunning = isApplicationRunning
        musicArtworkCache.countLimit = 8
    }

    @discardableResult
    func fetch(
        completion: @escaping (Result<MediaSnapshot, MediaIssue>) -> Void
    ) -> MediaCancellation {
        let cancellation = MediaCancellation()
        queue.async { [weak self] in
            guard let self, !cancellation.isCancelled else {
                return
            }
            guard isApplicationRunning() else {
                finish(
                    .failure(.applicationNotRunning),
                    cancellation: cancellation,
                    completion: completion
                )
                return
            }

            let result = run(
                scriptLines: metadataScript,
                cancellation: cancellation
            )
            guard !cancellation.isCancelled else {
                return
            }
            guard result.status == 0 else {
                finish(
                    .failure(
                        .automationFailure(
                            status: result.status,
                            errorOutput: result.errorOutput
                        )
                    ),
                    cancellation: cancellation,
                    completion: completion
                )
                return
            }

            switch MediaMetadataParser.parse(result.output) {
            case let .failure(issue):
                finish(
                    .failure(issue),
                    cancellation: cancellation,
                    completion: completion
                )
            case let .success(metadata):
                fetchArtwork(
                    for: metadata,
                    cancellation: cancellation,
                    completion: completion
                )
            }
        }
        return cancellation
    }

    @discardableResult
    func perform(
        command: MediaCommand,
        completion: @escaping (Result<Void, MediaIssue>) -> Void
    ) -> MediaCancellation {
        let cancellation = MediaCancellation()
        queue.async { [weak self] in
            guard let self, !cancellation.isCancelled else {
                return
            }
            guard isApplicationRunning() else {
                finish(
                    .failure(.applicationNotRunning),
                    cancellation: cancellation,
                    completion: completion
                )
                return
            }
            let result = run(
                scriptLines: commandScript(command),
                cancellation: cancellation
            )
            guard !cancellation.isCancelled else {
                return
            }
            if result.status == 0 {
                finish(
                    .success(()),
                    cancellation: cancellation,
                    completion: completion
                )
            } else {
                finish(
                    .failure(
                        .automationFailure(
                            status: result.status,
                            errorOutput: result.errorOutput
                        )
                    ),
                    cancellation: cancellation,
                    completion: completion
                )
            }
        }
        return cancellation
    }

    private func fetchArtwork(
        for metadata: ParsedMediaMetadata,
        cancellation: MediaCancellation,
        completion: @escaping (Result<MediaSnapshot, MediaIssue>) -> Void
    ) {
        let cacheKey = "\(metadata.title)\n\(metadata.artist)\n\(metadata.album)"
            as NSString
        if let image = musicArtworkCache.object(forKey: cacheKey) {
            finish(
                .success(metadata.snapshot(artwork: image)),
                cancellation: cancellation,
                completion: completion
            )
            return
        }

        let result = run(
            scriptLines: musicArtworkScript,
            cancellation: cancellation
        )
        guard !cancellation.isCancelled else {
            return
        }
        let data = result.status == 0
            ? Self.appleScriptDataDescriptor(from: result.output)
            : nil
        let image = data.flatMap(NSImage.init(data:))
        if let image {
            musicArtworkCache.setObject(image, forKey: cacheKey)
        }
        finish(
            .success(metadata.snapshot(artwork: image)),
            cancellation: cancellation,
            completion: completion
        )
    }

    private var metadataScript: [String] {
        let delimiter = MediaMetadataParser.delimiter
        let fields = [
            "(player state as string)",
            "(name of current track as string)",
            "(artist of current track as string)",
            "(album of current track as string)",
            "(duration of current track as string)",
            "(player position as string)",
        ]
        let joinedFields = fields.joined(separator: " & d & ")

        return [
            "tell application \"Music\"",
            "if player state is stopped then return \"\(MediaMetadataParser.stoppedMarker)\"",
            "set d to \"\(delimiter)\"",
            "return \(joinedFields)",
            "end tell",
        ]
    }

    private func commandScript(_ command: MediaCommand) -> [String] {
        let commandText: String
        switch command {
        case .togglePlayPause:
            commandText = "playpause"
        case .previous:
            commandText = "previous track"
        case .next:
            commandText = "next track"
        case let .seek(elapsedTime):
            commandText = "set player position to \(max(0, elapsedTime))"
        }
        return [
            "tell application \"Music\"",
            commandText,
            "end tell",
        ]
    }

    private var musicArtworkScript: [String] {
        [
            "tell application \"Music\"",
            "if (count of artwork of current track) is 0 then return \"\"",
            "return data of artwork 1 of current track",
            "end tell",
        ]
    }

    private func run(
        scriptLines: [String],
        cancellation: MediaCancellation
    ) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = scriptLines.flatMap { ["-e", $0] }
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        cancellation.add {
            if process.isRunning {
                process.terminate()
            }
        }
        guard !cancellation.isCancelled else {
            return ProcessResult(status: -1, output: "", errorOutput: "")
        }

        do {
            try process.run()
        } catch {
            return ProcessResult(
                status: -1,
                output: "",
                errorOutput: error.localizedDescription
            )
        }

        let drainGroup = DispatchGroup()
        let drainQueue = DispatchQueue(
            label: "com.ranveer.droppy.media.output",
            attributes: .concurrent
        )
        var outputData = Data()
        var errorData = Data()

        drainGroup.enter()
        drainQueue.async {
            outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            drainGroup.leave()
        }
        drainGroup.enter()
        drainQueue.async {
            errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            drainGroup.leave()
        }

        drainGroup.wait()
        process.waitUntilExit()
        return ProcessResult(
            status: process.terminationStatus,
            output: String(data: outputData, encoding: .utf8) ?? "",
            errorOutput: String(data: errorData, encoding: .utf8) ?? ""
        )
    }

    private func finish<Success>(
        _ result: Result<Success, MediaIssue>,
        cancellation: MediaCancellation,
        completion: @escaping (Result<Success, MediaIssue>) -> Void
    ) {
        guard !cancellation.isCancelled else {
            return
        }
        DispatchQueue.main.async {
            guard !cancellation.isCancelled else {
                return
            }
            completion(result)
        }
    }

    static func appleScriptDataDescriptor(from output: String) -> Data? {
        let compactOutput = output
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            compactOutput.hasPrefix("«data "),
            compactOutput.hasSuffix("»")
        else {
            return nil
        }

        let descriptorStart = compactOutput.index(
            compactOutput.startIndex,
            offsetBy: 6
        )
        let descriptorEnd = compactOutput.index(
            before: compactOutput.endIndex
        )
        let descriptorBody = compactOutput[descriptorStart..<descriptorEnd]
        guard descriptorBody.count > 4 else {
            return nil
        }
        let hexStart = descriptorBody.index(
            descriptorBody.startIndex,
            offsetBy: 4
        )
        let hexString = descriptorBody[hexStart...]
        guard hexString.count.isMultiple(of: 2) else {
            return nil
        }

        var data = Data()
        var index = hexString.startIndex
        while index < hexString.endIndex {
            guard let nextIndex = hexString.index(
                index,
                offsetBy: 2,
                limitedBy: hexString.endIndex
            ) else {
                return nil
            }
            let byteString = hexString[index..<nextIndex]
            guard let byte = UInt8(byteString, radix: 16) else {
                return nil
            }
            data.append(byte)
            index = nextIndex
        }
        return data
    }
}
