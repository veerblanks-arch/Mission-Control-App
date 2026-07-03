import AppKit
import Darwin
import QuartzCore

final class MediaPlayerFeature {
    static let shared = MediaPlayerFeature()
    static let phase = 2

    var onStateChange: ((MediaPlayerState) -> Void)?

    private let remoteClient = MediaRemoteClient()
    private let scriptClient = ScriptMediaClient()
    private var refreshTimer: Timer?
    private var pendingSeekWorkItem: DispatchWorkItem?
    private var lastLoggedStateKey = ""
    private var isRunning = false
    private(set) var state: MediaPlayerState = .empty

    private init() {}

    func start() {
        guard !isRunning else {
            onStateChange?(state)
            return
        }

        isRunning = true
        remoteClient.registerForNowPlayingNotifications()
        refresh()

        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(nowPlayingInfoDidChange),
            name: MediaRemoteClient.nowPlayingInfoDidChangeNotification,
            object: nil
        )
    }

    func stop() {
        guard isRunning else {
            return
        }

        isRunning = false
        pendingSeekWorkItem?.cancel()
        pendingSeekWorkItem = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        NotificationCenter.default.removeObserver(self)
    }

    func refresh() {
        scriptClient.fetchNowPlayingState { [weak self] scriptState in
            guard let self else {
                return
            }

            if let scriptState {
                updateState(scriptState)
                return
            }

            remoteClient.fetchNowPlayingInfo { [weak self] info in
                let remoteState = MediaPlayerState(info: info)
                self?.updateState(remoteState.isAvailable ? remoteState : .empty)
            }
        }
    }

    func togglePlayPause() {
        if !scriptClient.send(command: .togglePlayPause, to: state.source) {
            remoteClient.send(command: .togglePlayPause)
        }

        refreshSoon()
    }

    func nextTrack() {
        if !scriptClient.send(command: .nextTrack, to: state.source) {
            remoteClient.send(command: .nextTrack)
        }

        refreshSoon()
    }

    func previousTrack() {
        if !scriptClient.send(command: .previousTrack, to: state.source) {
            remoteClient.send(command: .previousTrack)
        }

        refreshSoon()
    }

    func seek(toProgress progress: Double) {
        guard state.duration > 0 else {
            return
        }

        let clampedProgress = max(0, min(1, progress))
        let elapsedTime = state.duration * clampedProgress
        let seekSource = state.source

        updateState(state.replacing(elapsedTime: elapsedTime))
        pendingSeekWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }

            if !scriptClient.seek(to: elapsedTime, in: seekSource) {
                remoteClient.setElapsedTime(elapsedTime)
            }

            refreshSoon()
        }

        pendingSeekWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    private func updateState(_ nextState: MediaPlayerState) {
        state = nextState
        onStateChange?(nextState)
        logStateChangeIfNeeded(nextState)
    }

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.refresh()
        }
    }

    @objc private func nowPlayingInfoDidChange() {
        refresh()
    }

    private func logStateChangeIfNeeded(_ state: MediaPlayerState) {
        let stateKey = "\(state.source)|\(state.title)|\(state.artist)|\(state.artwork != nil)|\(state.isAvailable)"
        guard stateKey != lastLoggedStateKey else {
            return
        }

        lastLoggedStateKey = stateKey
        NSLog(
            "Droppy Media: source=\(state.source) available=\(state.isAvailable) title=\"\(state.title)\" artist=\"\(state.artist)\" artwork=\(state.artwork != nil)"
        )
    }
}

enum MediaPlayerSource {
    case none
    case mediaRemote
    case music
    case spotify
}

struct MediaPlayerState {
    static let empty = MediaPlayerState(
        title: "No Music",
        artist: "Start Music or Spotify",
        album: "",
        artwork: nil,
        tintColor: .systemPink,
        elapsedTime: 0,
        duration: 0,
        playbackRate: 0,
        isAvailable: false,
        source: .none
    )

    let title: String
    let artist: String
    let album: String
    let artwork: NSImage?
    let tintColor: NSColor
    let elapsedTime: TimeInterval
    let duration: TimeInterval
    let playbackRate: Double
    let isAvailable: Bool
    let source: MediaPlayerSource

    var isPlaying: Bool {
        playbackRate > 0.05
    }

    var progress: Double {
        guard duration > 0 else {
            return 0
        }

        return max(0, min(1, elapsedTime / duration))
    }

    var subtitle: String {
        guard isAvailable else {
            return artist
        }

        if artist.isEmpty {
            return album
        }

        if album.isEmpty {
            return artist
        }

        return "\(artist) - \(album)"
    }

    var compactTitle: String {
        guard isAvailable else {
            return "\(title) - \(artist)"
        }

        if artist.isEmpty {
            return title
        }

        return "\(title) - \(artist)"
    }

    init(
        title: String,
        artist: String,
        album: String,
        artwork: NSImage?,
        tintColor: NSColor,
        elapsedTime: TimeInterval,
        duration: TimeInterval,
        playbackRate: Double,
        isAvailable: Bool,
        source: MediaPlayerSource
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artwork = artwork
        self.tintColor = tintColor
        self.elapsedTime = elapsedTime
        self.duration = duration
        self.playbackRate = playbackRate
        self.isAvailable = isAvailable
        self.source = source
    }

    func replacing(elapsedTime: TimeInterval) -> MediaPlayerState {
        MediaPlayerState(
            title: title,
            artist: artist,
            album: album,
            artwork: artwork,
            tintColor: tintColor,
            elapsedTime: max(0, min(duration, elapsedTime)),
            duration: duration,
            playbackRate: playbackRate,
            isAvailable: isAvailable,
            source: source
        )
    }

    init(info: [String: Any]?) {
        guard let info else {
            self = .empty
            return
        }

        let title = Self.stringValue(info[Keys.title])
        let artist = Self.stringValue(info[Keys.artist])
        let album = Self.stringValue(info[Keys.album])
        let artwork = Self.imageValue(info[Keys.artworkData])
        let duration = Self.timeValue(info[Keys.duration])
        let playbackRate = Self.doubleValue(info[Keys.playbackRate])
        let elapsedTime = Self.currentElapsedTime(from: info, playbackRate: playbackRate, duration: duration)
        let hasTrack = !title.isEmpty || !artist.isEmpty || artwork != nil

        self.init(
            title: title.isEmpty ? "Not Playing" : title,
            artist: artist,
            album: album,
            artwork: artwork,
            tintColor: Self.tintColor(from: artwork),
            elapsedTime: elapsedTime,
            duration: duration,
            playbackRate: playbackRate,
            isAvailable: hasTrack,
            source: hasTrack ? .mediaRemote : .none
        )
    }

    private enum Keys {
        static let title = "kMRMediaRemoteNowPlayingInfoTitle"
        static let artist = "kMRMediaRemoteNowPlayingInfoArtist"
        static let album = "kMRMediaRemoteNowPlayingInfoAlbum"
        static let artworkData = "kMRMediaRemoteNowPlayingInfoArtworkData"
        static let duration = "kMRMediaRemoteNowPlayingInfoDuration"
        static let elapsedTime = "kMRMediaRemoteNowPlayingInfoElapsedTime"
        static let timestamp = "kMRMediaRemoteNowPlayingInfoTimestamp"
        static let playbackRate = "kMRMediaRemoteNowPlayingInfoPlaybackRate"
    }

    private static func stringValue(_ value: Any?) -> String {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func timeValue(_ value: Any?) -> TimeInterval {
        doubleValue(value)
    }

    private static func doubleValue(_ value: Any?) -> Double {
        if let number = value as? NSNumber {
            return number.doubleValue
        }

        return value as? Double ?? 0
    }

    private static func imageValue(_ value: Any?) -> NSImage? {
        guard let data = value as? Data ?? value as? NSData as Data? else {
            return nil
        }

        return NSImage(data: data)
    }

    private static func currentElapsedTime(
        from info: [String: Any],
        playbackRate: Double,
        duration: TimeInterval
    ) -> TimeInterval {
        var elapsed = timeValue(info[Keys.elapsedTime])

        if playbackRate > 0.05 {
            if let timestamp = info[Keys.timestamp] as? Date {
                elapsed += Date().timeIntervalSince(timestamp) * playbackRate
            } else if let timestampNumber = info[Keys.timestamp] as? NSNumber {
                elapsed += (Date().timeIntervalSinceReferenceDate - timestampNumber.doubleValue) * playbackRate
            }
        }

        guard duration > 0 else {
            return max(0, elapsed)
        }

        return max(0, min(duration, elapsed))
    }

    fileprivate static func tintColor(from artwork: NSImage?) -> NSColor {
        guard
            let artwork,
            let cgImage = artwork.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            return .controlAccentColor
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let width = max(1, bitmap.pixelsWide)
        let height = max(1, bitmap.pixelsHigh)
        let stepX = max(1, width / 24)
        let stepY = max(1, height / 24)
        var redTotal: CGFloat = 0
        var greenTotal: CGFloat = 0
        var blueTotal: CGFloat = 0
        var samples: CGFloat = 0

        for y in stride(from: 0, to: height, by: stepY) {
            for x in stride(from: 0, to: width, by: stepX) {
                guard
                    let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                else {
                    continue
                }

                let alpha = color.alphaComponent
                guard alpha > 0.2 else {
                    continue
                }

                redTotal += color.redComponent * alpha
                greenTotal += color.greenComponent * alpha
                blueTotal += color.blueComponent * alpha
                samples += alpha
            }
        }

        guard samples > 0 else {
            return .controlAccentColor
        }

        let average = NSColor(
            calibratedRed: redTotal / samples,
            green: greenTotal / samples,
            blue: blueTotal / samples,
            alpha: 1
        )

        guard let sRGBAverage = average.usingColorSpace(.sRGB) else {
            return average
        }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        sRGBAverage.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        return NSColor(
            calibratedHue: hue,
            saturation: max(0.35, min(1, saturation * 1.15)),
            brightness: max(0.45, min(0.95, brightness * 1.05)),
            alpha: 1
        )
    }
}

final class MediaTouchBarView: NSView {
    var onPrevious: (() -> Void)?
    var onTogglePlayPause: (() -> Void)?
    var onNext: (() -> Void)?
    var onScrub: ((Double) -> Void)?

    private let artworkView = NSImageView()
    private let progressSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let previousButton = NSButton()
    private let playPauseButton = NSButton()
    private let nextButton = NSButton()
    private var currentTint: NSColor = .controlAccentColor
    private var ignoreProgressUpdatesUntil = Date.distantPast

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with state: MediaPlayerState) {
        let fallbackImage = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Media")
        fallbackImage?.isTemplate = true
        artworkView.image = state.artwork ?? fallbackImage
        artworkView.contentTintColor = state.artwork == nil ? .white : nil
        if Date() >= ignoreProgressUpdatesUntil {
            progressSlider.doubleValue = state.progress
        }
        progressSlider.isEnabled = state.isAvailable && state.duration > 0
        playPauseButton.image = NSImage(
            systemSymbolName: state.isPlaying ? "pause.fill" : "play.fill",
            accessibilityDescription: state.isPlaying ? "Pause" : "Play"
        )

        let tint = state.tintColor
        currentTint = tint
        artworkView.layer?.backgroundColor = tint.withAlphaComponent(state.isAvailable ? 0.85 : 0.45).cgColor
        artworkView.layer?.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor
        configureButtonTint(previousButton, tint: tint, isAvailable: state.isAvailable)
        configureButtonTint(playPauseButton, tint: tint, isAvailable: state.isAvailable)
        configureButtonTint(nextButton, tint: tint, isAvailable: state.isAvailable)
        wantsLayer = true
        layer?.borderColor = tint.withAlphaComponent(0.75).cgColor
        layer?.backgroundColor = tint.withAlphaComponent(state.isAvailable ? 0.32 : 0.14).cgColor
    }

    private func buildView() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.18).cgColor

        artworkView.imageScaling = .scaleProportionallyUpOrDown
        artworkView.wantsLayer = true
        artworkView.layer?.cornerRadius = 6
        artworkView.layer?.borderWidth = 1
        artworkView.layer?.masksToBounds = true
        artworkView.translatesAutoresizingMaskIntoConstraints = false

        progressSlider.target = self
        progressSlider.action = #selector(scrubChanged)
        progressSlider.isContinuous = true
        progressSlider.isEnabled = false
        progressSlider.controlSize = .mini

        configureButton(previousButton, symbolName: "backward.fill", action: #selector(previousTapped))
        configureButton(playPauseButton, symbolName: "play.fill", action: #selector(togglePlayPauseTapped))
        configureButton(nextButton, symbolName: "forward.fill", action: #selector(nextTapped))

        let buttonStack = NSStackView(views: [previousButton, playPauseButton, nextButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 4
        buttonStack.alignment = .centerY

        let rootStack = NSStackView(views: [artworkView, progressSlider, buttonStack])
        rootStack.orientation = .horizontal
        rootStack.spacing = 7
        rootStack.alignment = .centerY
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(rootStack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 244),
            heightAnchor.constraint(equalToConstant: 30),
            artworkView.widthAnchor.constraint(equalToConstant: 28),
            artworkView.heightAnchor.constraint(equalToConstant: 28),
            previousButton.widthAnchor.constraint(equalToConstant: 28),
            playPauseButton.widthAnchor.constraint(equalToConstant: 30),
            nextButton.widthAnchor.constraint(equalToConstant: 28),
            progressSlider.widthAnchor.constraint(equalToConstant: 82),
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            rootStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    private func configureButton(_ button: NSButton, symbolName: String, action: Selector) {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        image?.isTemplate = true
        button.image = image
        button.target = self
        button.action = action
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.wantsLayer = true
        button.layer?.cornerRadius = 5
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureButtonTint(_ button: NSButton, tint: NSColor, isAvailable: Bool) {
        button.contentTintColor = .white
        button.layer?.backgroundColor = tint.withAlphaComponent(isAvailable ? 0.9 : 0.48).cgColor
    }

    @objc private func previousTapped() {
        animatePress(previousButton)
        onPrevious?()
    }

    @objc private func togglePlayPauseTapped() {
        animatePress(playPauseButton)
        onTogglePlayPause?()
    }

    @objc private func nextTapped() {
        animatePress(nextButton)
        onNext?()
    }

    @objc private func scrubChanged() {
        ignoreProgressUpdatesUntil = Date().addingTimeInterval(0.8)
        onScrub?(progressSlider.doubleValue)
    }

    private func animatePress(_ button: NSButton) {
        guard let layer = button.layer else {
            return
        }

        let scaleAnimation = CABasicAnimation(keyPath: "transform.scale")
        scaleAnimation.fromValue = 0.82
        scaleAnimation.toValue = 1
        scaleAnimation.duration = 0.16
        scaleAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(scaleAnimation, forKey: "droppyButtonScale")

        let colorAnimation = CABasicAnimation(keyPath: "backgroundColor")
        colorAnimation.fromValue = NSColor.white.withAlphaComponent(0.85).cgColor
        colorAnimation.toValue = currentTint.withAlphaComponent(0.9).cgColor
        colorAnimation.duration = 0.2
        colorAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(colorAnimation, forKey: "droppyButtonColor")
    }
}

private final class ScriptMediaClient {
    private enum Constants {
        static let delimiter = "|||DROPPY|||"
    }

    private enum ScriptCommand {
        case togglePlayPause
        case nextTrack
        case previousTrack
    }

    private let queue = DispatchQueue(label: "com.ranveer.droppy.media.script", qos: .utility)
    private var cachedMusicArtworkKey: String?
    private var cachedMusicArtwork: NSImage?

    func fetchNowPlayingState(completion: @escaping (MediaPlayerState?) -> Void) {
        queue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async {
                    completion(nil)
                }
                return
            }

            let state = fetchMusicState() ?? fetchSpotifyState()
            DispatchQueue.main.async {
                completion(state)
            }
        }
    }

    func send(command: MediaRemoteClient.Command, to source: MediaPlayerSource) -> Bool {
        let scriptCommand: ScriptCommand

        switch command {
        case .togglePlayPause:
            scriptCommand = .togglePlayPause
        case .nextTrack:
            scriptCommand = .nextTrack
        case .previousTrack:
            scriptCommand = .previousTrack
        case .play, .pause:
            return false
        }

        switch source {
        case .music:
            runAsync(scriptLines: musicCommandScript(scriptCommand))
            return true
        case .spotify:
            runAsync(scriptLines: spotifyCommandScript(scriptCommand))
            return true
        case .mediaRemote, .none:
            return false
        }
    }

    func seek(to elapsedTime: TimeInterval, in source: MediaPlayerSource) -> Bool {
        switch source {
        case .music:
            runAsync(scriptLines: [
                "tell application \"Music\"",
                "set player position to \(max(0, elapsedTime))",
                "end tell"
            ])
            return true
        case .spotify:
            runAsync(scriptLines: [
                "tell application \"Spotify\"",
                "set player position to \(max(0, elapsedTime))",
                "end tell"
            ])
            return true
        case .mediaRemote, .none:
            return false
        }
    }

    private func fetchMusicState() -> MediaPlayerState? {
        guard isApplicationRunning(bundleIdentifier: "com.apple.Music") else {
            return nil
        }

        guard let output = runBestEffort(scriptLines: [
            "tell application \"Music\"",
            "if player state is stopped then return \"\"",
            "set d to \"\(Constants.delimiter)\"",
            "return (player state as string) & d & (name of current track as string) & d & (artist of current track as string) & d & (album of current track as string) & d & (duration of current track as string) & d & (player position as string)",
            "end tell"
        ]), !output.isEmpty else {
            return nil
        }

        let parts = output.components(separatedBy: Constants.delimiter)
        guard parts.count >= 6 else {
            return nil
        }

        let title = parts[1]
        let artist = parts[2]
        let album = parts[3]
        let duration = Double(parts[4]) ?? 0
        let elapsedTime = Double(parts[5]) ?? 0
        let artwork = musicArtwork(title: title, artist: artist, album: album)
        let tintColor = artwork.map { MediaPlayerState.tintColor(from: $0) } ?? .systemPink
        let isPlaying = parts[0] == "playing"

        return MediaPlayerState(
            title: title.isEmpty ? "Music" : title,
            artist: artist,
            album: album,
            artwork: artwork,
            tintColor: tintColor,
            elapsedTime: elapsedTime,
            duration: duration,
            playbackRate: isPlaying ? 1 : 0,
            isAvailable: !title.isEmpty || !artist.isEmpty,
            source: .music
        )
    }

    private func fetchSpotifyState() -> MediaPlayerState? {
        guard isApplicationRunning(bundleIdentifier: "com.spotify.client") else {
            return nil
        }

        guard let output = runBestEffort(scriptLines: [
            "tell application \"Spotify\"",
            "if player state is stopped then return \"\"",
            "set d to \"\(Constants.delimiter)\"",
            "return (player state as string) & d & (name of current track as string) & d & (artist of current track as string) & d & (album of current track as string) & d & (duration of current track as string) & d & (player position as string)",
            "end tell"
        ]), !output.isEmpty else {
            return nil
        }

        let parts = output.components(separatedBy: Constants.delimiter)
        guard parts.count >= 6 else {
            return nil
        }

        let title = parts[1]
        let artist = parts[2]
        let album = parts[3]
        let duration = (Double(parts[4]) ?? 0) / 1000
        let elapsedTime = Double(parts[5]) ?? 0
        let isPlaying = parts[0] == "playing"

        return MediaPlayerState(
            title: title.isEmpty ? "Spotify" : title,
            artist: artist,
            album: album,
            artwork: nil,
            tintColor: .systemGreen,
            elapsedTime: elapsedTime,
            duration: duration,
            playbackRate: isPlaying ? 1 : 0,
            isAvailable: !title.isEmpty || !artist.isEmpty,
            source: .spotify
        )
    }

    private func musicArtwork(title: String, artist: String, album: String) -> NSImage? {
        let key = "\(title)\n\(artist)\n\(album)"
        if cachedMusicArtworkKey == key {
            return cachedMusicArtwork
        }

        cachedMusicArtworkKey = key
        cachedMusicArtwork = nil

        guard let output = runProcess(scriptLines: [
            "tell application \"Music\"",
            "if (count of artwork of current track) is 0 then return \"\"",
            "return data of artwork 1 of current track",
            "end tell"
        ]), let artworkData = Self.appleScriptDataDescriptor(from: output) else {
            return nil
        }

        let artwork = NSImage(data: artworkData)
        cachedMusicArtwork = artwork
        return artwork
    }

    private func isApplicationRunning(bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    private func musicCommandScript(_ command: ScriptCommand) -> [String] {
        let commandText: String

        switch command {
        case .togglePlayPause:
            commandText = "playpause"
        case .nextTrack:
            commandText = "next track"
        case .previousTrack:
            commandText = "previous track"
        }

        return [
            "tell application \"Music\"",
            commandText,
            "end tell"
        ]
    }

    private func spotifyCommandScript(_ command: ScriptCommand) -> [String] {
        let commandText: String

        switch command {
        case .togglePlayPause:
            commandText = "playpause"
        case .nextTrack:
            commandText = "next track"
        case .previousTrack:
            commandText = "previous track"
        }

        return [
            "tell application \"Spotify\"",
            commandText,
            "end tell"
        ]
    }

    private func runAsync(scriptLines: [String]) {
        queue.async { [weak self] in
            _ = self?.runBestEffort(scriptLines: scriptLines)
        }
    }

    private func runBestEffort(scriptLines: [String]) -> String? {
        if let processOutput = runProcess(scriptLines: scriptLines), !processOutput.isEmpty {
            return processOutput
        }

        if let appleScriptOutput = run(scriptLines: scriptLines), !appleScriptOutput.isEmpty {
            return appleScriptOutput
        }

        return nil
    }

    private func run(scriptLines: [String]) -> String? {
        let scriptSource = scriptLines.joined(separator: "\n")
        var error: NSDictionary?
        guard let script = NSAppleScript(source: scriptSource) else {
            return nil
        }

        let descriptor = script.executeAndReturnError(&error)
        if let error {
            NSLog("Droppy Media: AppleScript fallback failed: \(error)")
            return nil
        }

        return descriptor.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runProcess(scriptLines: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = scriptLines.flatMap { ["-e", $0] }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            NSLog("Droppy Media: could not run AppleScript fallback: \(error)")
            return nil
        }

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errorMessage = String(data: errorOutput, encoding: .utf8) ?? ""
            NSLog("Droppy Media: osascript fallback failed: \(errorMessage)")
            return nil
        }

        return String(data: output, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func appleScriptDataDescriptor(from output: String) -> Data? {
        let compactOutput = output
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard compactOutput.hasPrefix("«data "), compactOutput.hasSuffix("»") else {
            return nil
        }

        let descriptorStart = compactOutput.index(compactOutput.startIndex, offsetBy: 6)
        let descriptorEnd = compactOutput.index(before: compactOutput.endIndex)
        let descriptorBody = compactOutput[descriptorStart..<descriptorEnd]

        guard descriptorBody.count > 4 else {
            return nil
        }

        let hexStart = descriptorBody.index(descriptorBody.startIndex, offsetBy: 4)
        let hexString = descriptorBody[hexStart...]
        var data = Data()
        var index = hexString.startIndex

        while index < hexString.endIndex {
            let nextIndex = hexString.index(index, offsetBy: 2, limitedBy: hexString.endIndex) ?? hexString.endIndex
            guard nextIndex <= hexString.endIndex else {
                return nil
            }

            let byteString = hexString[index..<nextIndex]
            guard byteString.count == 2, let byte = UInt8(byteString, radix: 16) else {
                return nil
            }

            data.append(byte)
            index = nextIndex
        }

        return data
    }
}

private final class MediaRemoteClient {
    static let nowPlayingInfoDidChangeNotification = Notification.Name("kMRMediaRemoteNowPlayingInfoDidChangeNotification")

    enum Command: Int32 {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case nextTrack = 4
        case previousTrack = 5
    }

    private let handle: UnsafeMutableRawPointer?
    private let getNowPlayingInfo: GetNowPlayingInfoFunction?
    private let sendCommandFunction: SendCommandFunction?
    private let setElapsedTimeFunction: SetElapsedTimeFunction?
    private let registerNotifications: RegisterNotificationsFunction?

    private typealias NowPlayingInfoCallback = @convention(block) (CFDictionary?) -> Void
    private typealias GetNowPlayingInfoFunction = @convention(c) (DispatchQueue, NowPlayingInfoCallback) -> Void
    private typealias SendCommandFunction = @convention(c) (Int32, CFDictionary?) -> Void
    private typealias SetElapsedTimeFunction = @convention(c) (Double) -> Void
    private typealias RegisterNotificationsFunction = @convention(c) (DispatchQueue) -> Void

    init() {
        handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)

        getNowPlayingInfo = Self.loadSymbol(
            named: "MRMediaRemoteGetNowPlayingInfo",
            from: handle,
            as: GetNowPlayingInfoFunction.self
        )
        sendCommandFunction = Self.loadSymbol(
            named: "MRMediaRemoteSendCommand",
            from: handle,
            as: SendCommandFunction.self
        )
        setElapsedTimeFunction = Self.loadSymbol(
            named: "MRMediaRemoteSetElapsedTime",
            from: handle,
            as: SetElapsedTimeFunction.self
        )
        registerNotifications = Self.loadSymbol(
            named: "MRMediaRemoteRegisterForNowPlayingNotifications",
            from: handle,
            as: RegisterNotificationsFunction.self
        )
    }

    deinit {
        if let handle {
            dlclose(handle)
        }
    }

    func registerForNowPlayingNotifications() {
        registerNotifications?(DispatchQueue.main)
    }

    func fetchNowPlayingInfo(completion: @escaping ([String: Any]?) -> Void) {
        guard let getNowPlayingInfo else {
            NSLog("Droppy Media: MediaRemote now-playing function is unavailable.")
            completion(nil)
            return
        }

        let callback: NowPlayingInfoCallback = { info in
            let dictionary = info as? [String: Any]

            DispatchQueue.main.async {
                completion(dictionary)
            }
        }

        getNowPlayingInfo(DispatchQueue.global(qos: .utility), callback)
    }

    func send(command: Command) {
        guard let sendCommandFunction else {
            NSLog("Droppy Media: MediaRemote command function is unavailable.")
            return
        }

        sendCommandFunction(command.rawValue, nil)
    }

    func setElapsedTime(_ elapsedTime: TimeInterval) {
        guard let setElapsedTimeFunction else {
            NSLog("Droppy Media: MediaRemote elapsed-time function is unavailable.")
            return
        }

        setElapsedTimeFunction(max(0, elapsedTime))
    }

    private static func loadSymbol<T>(
        named name: String,
        from handle: UnsafeMutableRawPointer?,
        as type: T.Type
    ) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else {
            return nil
        }

        return unsafeBitCast(symbol, to: type)
    }
}
