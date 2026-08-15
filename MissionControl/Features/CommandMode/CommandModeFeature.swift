import AppKit
import Foundation

final class CommandFileSearchService {
    func search(
        _ rawQuery: String,
        rootURL: URL,
        completion: @escaping ([URL]) -> Void
    ) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            completion([])
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            process.arguments = [
                "-onlyin",
                rootURL.path,
                Self.metadataQuery(for: query),
            ]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    DispatchQueue.main.async { completion([]) }
                    return
                }

                let paths = String(decoding: data, as: UTF8.self)
                    .split(separator: "\n")
                    .map(String.init)
                let urls = Self.rankedURLs(paths: paths, query: query)
                DispatchQueue.main.async { completion(urls) }
            } catch {
                DispatchQueue.main.async { completion([]) }
            }
        }
    }

    private static func escapedMetadataValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func metadataQuery(for query: String) -> String {
        query
            .split(whereSeparator: \.isWhitespace)
            .map { escapedMetadataValue(String($0)) }
            .map { "kMDItemFSName == \"*\($0)*\"cd" }
            .joined(separator: " && ")
    }

    private static func rankedURLs(paths: [String], query: String) -> [URL] {
        let fileManager = FileManager.default
        let normalizedQuery = query.lowercased()
        let candidates = paths.compactMap { path -> (URL, Date, Int)? in
            guard fileManager.fileExists(atPath: path) else { return nil }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard !url.pathComponents.contains("Library") else { return nil }
            let values = try? url.resourceValues(forKeys: [
                .contentModificationDateKey,
                .isHiddenKey,
            ])
            guard values?.isHidden != true else { return nil }
            let name = url.deletingPathExtension().lastPathComponent.lowercased()
            let score: Int
            if name == normalizedQuery {
                score = 0
            } else if name.hasPrefix(normalizedQuery) {
                score = 1
            } else {
                score = 2
            }
            return (url, values?.contentModificationDate ?? .distantPast, score)
        }
        return candidates
            .sorted {
                if $0.2 != $1.2 { return $0.2 < $1.2 }
                return $0.1 > $1.1
            }
            .prefix(8)
            .map(\.0)
    }
}

@MainActor
final class CommandModeFeature: ObservableObject {
    static let shared = CommandModeFeature()

    @Published var query = "" {
        didSet { refreshSuggestions() }
    }
    @Published private(set) var suggestions: [CommandResolution] = []
    @Published private(set) var choices: [CommandChoice] = []
    @Published private(set) var executionState: CommandExecutionState = .idle
    @Published private(set) var presentationID = UUID()

    let voice: CommandVoiceInput
    let conversation: ConversationalVoiceFeature

    var onShowFeature: ((OverlayFeature) -> Void)?
    var onDismiss: (() -> Void)?
    var onShowSettings: (() -> Void)? {
        didSet { conversation.onShowSettings = onShowSettings }
    }

    private let workspace: NSWorkspace
    private let fileManager: FileManager
    private let homeURL: URL
    private let fileSearch: CommandFileSearchService
    private let notion: NotionConnectorFeature
    private let codex: CodexFeature
    private var applications: [CommandApplication]

    convenience init() {
        self.init(
            workspace: .shared,
            fileManager: .default,
            homeURL: FileManager.default.homeDirectoryForCurrentUser,
            fileSearch: CommandFileSearchService(),
            voice: CommandVoiceInput(),
            conversation: ConversationalVoiceFeature(),
            notion: .shared,
            codex: .shared,
            applications: nil
        )
    }

    init(
        workspace: NSWorkspace = .shared,
        fileManager: FileManager = .default,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileSearch: CommandFileSearchService = CommandFileSearchService(),
        voice: CommandVoiceInput,
        conversation: ConversationalVoiceFeature,
        notion: NotionConnectorFeature,
        codex: CodexFeature,
        applications: [CommandApplication]? = nil
    ) {
        self.workspace = workspace
        self.fileManager = fileManager
        self.homeURL = homeURL
        self.fileSearch = fileSearch
        self.voice = voice
        self.conversation = conversation
        self.notion = notion
        self.codex = codex
        self.applications = applications
            ?? Self.discoverApplications(fileManager: fileManager, homeURL: homeURL)
        voice.onStateChange = { [weak conversation] state in
            conversation?.handleVoiceState(state)
        }
        voice.onTranscript = { [weak self] transcript in
            guard let self else { return }
            self.conversation.receivePartialTranscript(transcript)
            self.query = self.conversation.liveUserTranscript
        }
        voice.onSubmit = { [weak self] transcript in
            guard let self else { return }
            self.query = ""
            self.conversation.receiveFinalTranscript(transcript)
        }
        conversation.onListeningRequested = { [weak voice] in voice?.start() }
        conversation.onListeningCancelled = { [weak voice] in voice?.cancel() }
        conversation.onUserRequest = { [weak self] request in
            self?.performConversationRequest(request)
        }
        conversation.onHardInterruptRequested = { [weak self] threadID in
            self?.interruptVoiceCodexTask(threadID)
        }
        codex.onManagedTurnDelta = { [weak conversation] threadID, delta in
            conversation?.receiveCodexDelta(threadID: threadID, delta: delta)
        }
        codex.onManagedTurnCompleted = { [weak conversation] threadID, message in
            conversation?.notifyCodexCompleted(threadID: threadID, result: message)
        }
        codex.onManagedTurnInterrupted = { [weak conversation] threadID in
            conversation?.notifyCodexInterrupted(threadID: threadID)
        }
        codex.onManagedTurnFailed = { [weak conversation] threadID, message in
            conversation?.notifyCodexFailed(threadID: threadID, message: message)
        }
        refreshSuggestions()
    }

    func prepareForPresentation() {
        voice.cancel()
        conversation.prepareForPresentation()
        query = ""
        choices = []
        executionState = .idle
        applications = Self.discoverApplications(
            fileManager: fileManager,
            homeURL: homeURL
        )
        presentationID = UUID()
        refreshSuggestions()
    }

    func toggleVoice() {
        voice.cancel()
        conversation.toggle(projectNames: codex.availableProjects.map(\.name))
    }

    func startVoiceFromShortcut() {
        guard
            codex.pendingApprovals.isEmpty,
            codex.pendingUserInputs.isEmpty
        else { return }
        choices = []
        executionState = .idle
        query = ""
        voice.cancel()
        conversation.start(projectNames: codex.availableProjects.map(\.name))
    }

    func cancelVoice() {
        voice.cancel()
        conversation.stop()
    }

    func submit() {
        if conversation.isSessionActive {
            let text = query
            query = ""
            conversation.sendText(text)
            return
        }
        guard let resolution = resolve(query) else { return }
        execute(resolution)
    }

    func fill(_ resolution: CommandResolution) {
        execute(resolution)
    }

    func execute(
        _ resolution: CommandResolution,
        dismissOnSuccess: Bool = true,
        completion: ((Bool, String) -> Void)? = nil
    ) {
        choices = []
        switch resolution.route {
        case let .showFeature(feature):
            let message = "Opening \(feature.title)"
            executionState = .succeeded(message)
            if dismissOnSuccess { onDismiss?() }
            onShowFeature?(feature)
            completion?(true, message)

        case let .openURL(url):
            finishLocalOpen(
                succeeded: workspace.open(url),
                successMessage: "Opened \(resolution.title.replacingOccurrences(of: "Open ", with: ""))",
                dismissOnSuccess: dismissOnSuccess,
                completion: completion
            )

        case let .openPath(url):
            finishLocalOpen(
                succeeded: workspace.open(url),
                successMessage: "Opened \(url.lastPathComponent.isEmpty ? "Home" : url.lastPathComponent)",
                dismissOnSuccess: dismissOnSuccess,
                completion: completion
            )

        case let .openApplication(application):
            executionState = .working("Opening \(application.name)…")
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            workspace.openApplication(at: application.url, configuration: configuration) {
                [weak self] _, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.finishLocalOpen(
                        succeeded: error == nil,
                        successMessage: "Opened \(application.name)",
                        errorMessage: error?.localizedDescription,
                        dismissOnSuccess: dismissOnSuccess,
                        completion: completion
                    )
                }
            }

        case .openNotionCalendar:
            notion.openCalendar()
            finishLocalOpen(
                succeeded: true,
                successMessage: "Opened Notion Calendar",
                dismissOnSuccess: dismissOnSuccess,
                completion: completion
            )

        case let .searchFiles(searchQuery, openFirst):
            searchFiles(
                searchQuery,
                openFirst: openFirst,
                dismissOnSuccess: dismissOnSuccess,
                completion: completion
            )

        case let .codex(prompt, projectPath):
            startCodex(prompt: prompt, projectPath: projectPath)
            completion?(false, "Complex work must use the Codex voice tool.")
        }
    }

    func resolve(_ value: String) -> CommandResolution? {
        CommandModeResolver.resolve(
            value,
            applications: applications,
            notionShortcuts: notion.shortcuts,
            projects: codex.availableProjects,
            homeURL: homeURL
        )
    }

    private func refreshSuggestions() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            suggestions = CommandModeResolver.defaultSuggestions(
                applications: applications,
                notionShortcuts: notion.shortcuts,
                projects: codex.availableProjects,
                homeURL: homeURL
            )
            return
        }
        suggestions = resolve(trimmed).map { [$0] } ?? []
    }

    private func searchFiles(
        _ searchQuery: String,
        openFirst: Bool,
        dismissOnSuccess: Bool = true,
        completion: ((Bool, String) -> Void)? = nil
    ) {
        executionState = .working("Searching for \(searchQuery)…")
        fileSearch.search(searchQuery, rootURL: homeURL) { [weak self] urls in
            guard let self else { return }
            guard !urls.isEmpty else {
                let message = "No files matched “\(searchQuery)”."
                self.executionState = .failed(message)
                completion?(false, message)
                return
            }

            if openFirst, urls.count == 1 {
                self.finishLocalOpen(
                    succeeded: self.workspace.open(urls[0]),
                    successMessage: "Opened \(urls[0].lastPathComponent)",
                    dismissOnSuccess: dismissOnSuccess,
                    completion: completion
                )
                return
            }

            if completion != nil {
                let names = urls.prefix(5).map(\.lastPathComponent).joined(separator: ", ")
                let message = "Multiple files matched: \(names)."
                self.executionState = .failed(message)
                completion?(false, message)
                return
            }

            self.executionState = .idle
            self.choices = urls.map { url in
                let resolution = CommandResolution(
                    title: "Open \(url.lastPathComponent)",
                    subtitle: url.deletingLastPathComponent().path,
                    symbolName: url.hasDirectoryPath ? "folder" : "doc",
                    route: .openPath(url)
                )
                return CommandChoice(
                    title: url.lastPathComponent,
                    subtitle: url.deletingLastPathComponent().path,
                    symbolName: url.hasDirectoryPath ? "folder" : "doc",
                    resolution: resolution
                )
            }
        }
    }

    private func startCodex(prompt: String, projectPath: String?) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            executionState = .failed("Enter a request for Codex.")
            return
        }

        if let projectPath {
            executionState = .working("Starting a Codex task…")
            codex.createTask(
                prompt: trimmedPrompt,
                projectPath: projectPath,
                role: .planner,
                attachments: []
            ) { [weak self] succeeded in
                guard let self else { return }
                if succeeded {
                    self.executionState = .succeeded("Codex is working on it.")
                    self.dismissAfterSuccess()
                } else {
                    self.executionState = .failed(
                        self.codex.lastIssue ?? "Codex could not start the task."
                    )
                }
            }
            return
        }

        executionState = .idle
        choices = codex.availableProjects.map { project in
            let resolution = CommandResolution(
                title: "Ask Codex in \(project.name)",
                subtitle: project.path,
                symbolName: "sparkles",
                route: .codex(prompt: trimmedPrompt, projectPath: project.path)
            )
            return CommandChoice(
                title: project.name,
                subtitle: project.path,
                symbolName: "folder.badge.gearshape",
                resolution: resolution
            )
        }
    }

    private func finishLocalOpen(
        succeeded: Bool,
        successMessage: String,
        errorMessage: String? = nil,
        dismissOnSuccess: Bool = true,
        completion: ((Bool, String) -> Void)? = nil
    ) {
        if succeeded {
            executionState = .succeeded(successMessage)
            if dismissOnSuccess { dismissAfterSuccess() }
            completion?(true, successMessage)
        } else {
            let message = errorMessage ?? "Silverdeck could not open that target."
            executionState = .failed(message)
            completion?(false, message)
        }
    }

    private func performConversationRequest(_ request: String) {
        guard let resolution = resolve(request) else {
            conversation.deliverLocalResponse(
                "I could not understand that request.",
                succeeded: false
            )
            return
        }

        if case let .codex(prompt, projectPath) = resolution.route {
            continueOrStartVoiceCodexTask(prompt: prompt, projectPath: projectPath)
        } else {
            performConversationLocalAction(resolution)
        }
    }

    private func performConversationLocalAction(_ resolution: CommandResolution) {
        let perform = { [weak self] in
            guard let self else { return }
            self.execute(resolution, dismissOnSuccess: false) { succeeded, message in
                self.conversation.deliverLocalResponse(message, succeeded: succeeded)
            }
        }

        guard
            let threadID = conversation.activeCodexThreadID,
            let thread = codex.threads.first(where: { $0.id == threadID })
                ?? (codex.selectedThread?.id == threadID ? codex.selectedThread : nil),
            thread.status.isRunning
        else {
            perform()
            return
        }

        conversation.setActiveCodexThread(nil)
        codex.interruptActiveTurn(threadID: threadID) { _ in perform() }
    }

    private func continueOrStartVoiceCodexTask(
        prompt: String,
        projectPath: String?
    ) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            conversation.deliverLocalResponse("What would you like me to do?", succeeded: false)
            return
        }

        guard let threadID = conversation.activeCodexThreadID else {
            startVoiceCodexThread(prompt: trimmedPrompt, projectPath: projectPath)
            return
        }
        guard let thread = codex.threads.first(where: { $0.id == threadID })
            ?? (codex.selectedThread?.id == threadID ? codex.selectedThread : nil)
        else {
            conversation.setActiveCodexThread(nil)
            startVoiceCodexThread(prompt: trimmedPrompt, projectPath: projectPath)
            return
        }

        if let projectPath, URL(fileURLWithPath: projectPath).standardizedFileURL.path
            != URL(fileURLWithPath: thread.cwd).standardizedFileURL.path
        {
            conversation.setActiveCodexThread(nil)
            let startNew = { [weak self] in
                self?.startVoiceCodexThread(prompt: trimmedPrompt, projectPath: projectPath)
            }
            if thread.status.isRunning {
                codex.interruptActiveTurn(threadID: threadID) { _ in startNew() }
            } else {
                startNew()
            }
            return
        }

        if thread.status.isRunning {
            codex.steerActiveTurn(prompt: trimmedPrompt, threadID: threadID) {
                [weak self] succeeded in
                guard let self, !succeeded else { return }
                self.conversation.notifyCodexFailed(
                    threadID: threadID,
                    message: self.codex.lastIssue ?? "Codex could not accept the interruption."
                )
            }
        } else if thread.status == .waiting {
            conversation.deliverLocalResponse(
                "Codex needs an approval or answer in this window before it can continue.",
                succeeded: false
            )
        } else {
            codex.sendReply(prompt: trimmedPrompt, attachments: [], to: thread) {
                [weak self] succeeded in
                guard let self, !succeeded else { return }
                self.conversation.notifyCodexFailed(
                    threadID: threadID,
                    message: self.codex.lastIssue ?? "Codex could not receive the follow-up."
                )
            }
        }
    }

    private func startVoiceCodexThread(prompt: String, projectPath: String?) {
        let cwd: String
        let codexPrompt: String
        if let projectPath {
            cwd = projectPath
            codexPrompt = CodexVoicePrompt.initial(prompt)
        } else {
            do {
                cwd = try voiceWorkspaceURL().path
            } catch {
                conversation.deliverLocalResponse(error.localizedDescription, succeeded: false)
                return
            }
            codexPrompt = CodexVoicePrompt.initial(prompt)
        }

        executionState = .working("Starting a Codex conversation…")
        codex.createTask(
            prompt: codexPrompt,
            projectPath: cwd,
            role: .planner,
            attachments: [],
            displayPrompt: prompt
        ) { [weak self] succeeded in
            guard let self else { return }
            guard succeeded, let threadID = self.codex.selectedThread?.id else {
                let message = self.codex.lastIssue ?? "Codex could not start the conversation."
                self.executionState = .failed(message)
                self.conversation.deliverLocalResponse(message, succeeded: false)
                return
            }
            self.conversation.setActiveCodexThread(threadID)
            self.executionState = .succeeded("Codex is responding.")
        }
    }

    private func interruptVoiceCodexTask(_ threadID: String) {
        guard let thread = codex.threads.first(where: { $0.id == threadID })
            ?? (codex.selectedThread?.id == threadID ? codex.selectedThread : nil)
        else {
            conversation.notifyCodexInterrupted(threadID: threadID)
            return
        }
        guard thread.status.isRunning else {
            conversation.notifyCodexInterrupted(threadID: threadID)
            return
        }
        codex.interruptActiveTurn(threadID: threadID) { [weak self] succeeded in
            guard let self, !succeeded else { return }
            self.conversation.notifyCodexFailed(
                threadID: threadID,
                message: self.codex.lastIssue ?? "Codex could not stop the current response."
            )
        }
    }

    private func voiceWorkspaceURL() throws -> URL {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let workspace = root
            .appendingPathComponent("Silverdeck", isDirectory: true)
            .appendingPathComponent("VoiceWorkspace", isDirectory: true)
        try fileManager.createDirectory(
            at: workspace,
            withIntermediateDirectories: true
        )
        return workspace
    }

    private func dismissAfterSuccess() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            guard let self else { return }
            if case .succeeded = self.executionState {
                self.onDismiss?()
            }
        }
    }

    static func discoverApplications(
        fileManager: FileManager,
        homeURL: URL
    ) -> [CommandApplication] {
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            homeURL.appendingPathComponent("Applications", isDirectory: true),
        ]
        var applicationsByPath: [String: CommandApplication] = [:]
        for root in roots {
            guard let urls = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isApplicationKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in urls where url.pathExtension.lowercased() == "app" {
                let standardized = url.standardizedFileURL
                let application = CommandApplication(
                    name: standardized.deletingPathExtension().lastPathComponent,
                    url: standardized,
                    bundleIdentifier: Bundle(url: standardized)?.bundleIdentifier
                )
                applicationsByPath[application.id] = application
            }
        }
        return applicationsByPath.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
