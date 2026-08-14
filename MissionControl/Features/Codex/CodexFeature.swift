import AppKit
import Foundation

@MainActor
final class CodexFeature: ObservableObject {
    private enum OwnershipState: String, Codable {
        case managed
        case handedOff
    }

    private struct OwnershipRecord: Codable {
        let state: OwnershipState
        let role: CodexAgentRole
    }

    static let shared = CodexFeature()

    @Published private(set) var connectionState: CodexConnectionState = .stopped
    @Published private(set) var threads: [CodexThreadSummary] = []
    @Published private(set) var selectedThread: CodexThreadSummary?
    @Published private(set) var messages: [CodexChatMessage] = []
    @Published private(set) var usagePercent: Int?
    @Published private(set) var isLoadingThread = false
    @Published private(set) var isSending = false
    @Published private(set) var isHandingOff = false
    @Published private(set) var isTakingBack = false
    @Published private(set) var recentlyCompletedThreadIDs: Set<String> = []
    @Published private(set) var managedThreadIDs: Set<String>
    @Published private(set) var pendingApprovals: [CodexApprovalRequest] = []
    @Published private(set) var pendingUserInputs: [CodexUserInputRequest] = []
    @Published var projectQuery = ""
    @Published var lastIssue: String?

    private let client: CodexAppServerClient
    private let defaults: UserDefaults
    private let ownershipRecordsKey = "codexThreadOwnershipRecords"
    private let roleAssignmentsKey = "codexThreadRoleAssignments"
    private let handedOffRoleAssignmentsKey = "codexHandedOffRoleAssignments"
    private var ownershipRecords: [String: OwnershipRecord]
    private var roleAssignments: [String: CodexAgentRole]
    private var handedOffRoleAssignments: [String: CodexAgentRole]
    private var refreshTimer: Timer?
    private var hasStarted = false
    private var shouldReconnect = false
    private var reconnectAttempt = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var completedTurnIDs: Set<String> = []
    private var completionClearWorkItems: [String: DispatchWorkItem] = [:]
    private var modelsByThreadID: [String: String] = [:]
    private var loadedHistoryDates: [String: Date] = [:]
    private var historyLoadToken: UUID?
    private var threadRefreshToken: UUID?
    private var activeTurnIDsByThreadID: [String: String] = [:]
    var onApprovalNeeded: (() -> Void)?
    var onManagedTurnCompleted: ((String, String?) -> Void)?

    init(
        client: CodexAppServerClient = CodexAppServerClient(),
        defaults: UserDefaults = .standard
    ) {
        self.client = client
        self.defaults = defaults
        let legacyManaged: [String: CodexAgentRole]
        if
            let data = defaults.data(forKey: roleAssignmentsKey),
            let stored = try? JSONDecoder().decode([String: CodexAgentRole].self, from: data)
        {
            legacyManaged = stored
        } else {
            legacyManaged = [:]
        }
        let legacyHandedOff: [String: CodexAgentRole]
        if
            let data = defaults.data(forKey: handedOffRoleAssignmentsKey),
            let stored = try? JSONDecoder().decode([String: CodexAgentRole].self, from: data)
        {
            legacyHandedOff = stored
        } else {
            legacyHandedOff = [:]
        }

        if
            let data = defaults.data(forKey: ownershipRecordsKey),
            let stored = try? JSONDecoder().decode([String: OwnershipRecord].self, from: data)
        {
            ownershipRecords = stored
        } else {
            var migrated = legacyManaged.mapValues {
                OwnershipRecord(state: .managed, role: $0)
            }
            for (threadID, role) in legacyHandedOff {
                // A legacy conflict means unsubscribe had already succeeded before
                // the old two-write handoff sequence was interrupted.
                migrated[threadID] = OwnershipRecord(state: .handedOff, role: role)
            }
            ownershipRecords = migrated
            if let data = try? JSONEncoder().encode(migrated) {
                defaults.set(data, forKey: ownershipRecordsKey)
            }
        }
        roleAssignments = ownershipRecords.compactMapValues {
            $0.state == .managed ? $0.role : nil
        }
        handedOffRoleAssignments = ownershipRecords.compactMapValues {
            $0.state == .handedOff ? $0.role : nil
        }
        managedThreadIDs = Set(roleAssignments.keys)

        client.onNotification = { [weak self] method, params in
            self?.handleNotification(method: method, params: params)
        }
        client.onProtectedRequest = { [weak self] requestID, method, params in
            self?.handleProtectedRequest(
                requestID: requestID,
                method: method,
                params: params
            )
        }
        client.onDisconnect = { [weak self] message in
            guard let self else { return }
            self.hasStarted = false
            self.connectionState = .failed(message)
            self.threadRefreshToken = nil
            self.historyLoadToken = nil
            self.isLoadingThread = false
            self.pendingApprovals = []
            self.pendingUserInputs = []
            self.threads = self.threads.map { $0.replacing(status: .unavailable) }
            if let selectedThread = self.selectedThread {
                self.selectedThread = selectedThread.replacing(status: .unavailable)
            }
            self.refreshTimer?.invalidate()
            self.refreshTimer = nil
            self.scheduleReconnect()
        }
    }

    func start() {
        shouldReconnect = true
        reconnectAttempt = 0
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        connect()
    }

    private func connect() {
        guard !hasStarted else { return }
        hasStarted = true
        connectionState = .connecting
        client.start { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.reconnectAttempt = 0
                self.connectionState = .ready
                self.refresh()
                self.scheduleRefreshes()
            case let .failure(error):
                self.hasStarted = false
                self.connectionState = .failed(error.localizedDescription)
                self.scheduleReconnect()
            }
        }
    }

    func stop() {
        shouldReconnect = false
        reconnectAttempt = 0
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        hasStarted = false
        refreshTimer?.invalidate()
        refreshTimer = nil
        completionClearWorkItems.values.forEach { $0.cancel() }
        completionClearWorkItems.removeAll()
        recentlyCompletedThreadIDs.removeAll()
        activeTurnIDsByThreadID.removeAll()
        client.stop()
        connectionState = .stopped
        pendingApprovals = []
        pendingUserInputs = []
    }

    func refresh() {
        guard connectionState == .ready else { return }
        let token = UUID()
        threadRefreshToken = token
        loadThreadPage(cursor: nil, accumulated: [], seenCursors: [], token: token)
        refreshUsage()
    }

    private func loadThreadPage(
        cursor: String?,
        accumulated: [CodexThreadSummary],
        seenCursors: Set<String>,
        token: UUID
    ) {
        var params: [String: Any] = [
            "archived": false,
            "limit": 100,
            "sortKey": "recency_at",
            "sortDirection": "desc",
        ]
        if let cursor { params["cursor"] = cursor }
        client.request(
            method: "thread/list",
            params: params
        ) { [weak self] result in
            guard let self, self.threadRefreshToken == token else { return }
            switch result {
            case let .success(payload):
                let values = payload["data"] as? [[String: Any]] ?? []
                let combined = accumulated + values.compactMap { Self.parseThread($0) }
                if
                    let nextCursor = payload["nextCursor"] as? String,
                    !nextCursor.isEmpty,
                    !seenCursors.contains(nextCursor)
                {
                    var nextSeenCursors = seenCursors
                    nextSeenCursors.insert(nextCursor)
                    self.loadThreadPage(
                        cursor: nextCursor,
                        accumulated: combined,
                        seenCursors: nextSeenCursors,
                        token: token
                    )
                } else {
                    var seenThreadIDs = Set<String>()
                    self.applyThreadList(combined.filter { seenThreadIDs.insert($0.id).inserted })
                }
            case let .failure(error):
                self.lastIssue = error.localizedDescription
            }
        }
    }

    var displayedProjectGroups: [CodexProjectGroup] {
        Self.dashboardGroups(from: threads, matching: projectQuery)
    }

    static func dashboardGroups(
        from threads: [CodexThreadSummary],
        matching query: String = ""
    ) -> [CodexProjectGroup] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var projectThreads: [String: [CodexThreadSummary]] = [:]
        var normalThreads: [CodexThreadSummary] = []

        for thread in threads {
            if let project = recentProject(for: thread.cwd) {
                projectThreads[project.id, default: []].append(thread)
            } else {
                normalThreads.append(thread)
            }
        }

        var groups = recentProjects.compactMap { project -> CodexProjectGroup? in
            guard let matches = projectThreads[project.id], !matches.isEmpty else { return nil }
            return CodexProjectGroup(
                id: project.id,
                name: project.name,
                subtitle: project.primaryPath,
                kind: .recentProject,
                threads: matches.sorted { $0.updatedAt > $1.updatedAt }
            )
        }
        .filter { groupMatchesQuery($0, query: normalizedQuery) }
        .sorted {
            let leftDate = $0.threads.first?.updatedAt ?? .distantPast
            let rightDate = $1.threads.first?.updatedAt ?? .distantPast
            if leftDate == rightDate {
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return leftDate > rightDate
        }

        if !normalThreads.isEmpty {
            let normalGroup = CodexProjectGroup(
                id: "normal-chats",
                name: "Normal Chats",
                subtitle: "Chats outside recent projects",
                kind: .normalChats,
                threads: normalThreads.sorted { $0.updatedAt > $1.updatedAt }
            )
            if groupMatchesQuery(normalGroup, query: normalizedQuery) {
                groups.append(normalGroup)
            }
        }
        return groups
    }

    private struct RecentProject {
        let id: String
        let name: String
        let primaryPath: String
        let matchingPathComponents: Set<String>
    }

    private static let recentProjects = [
        RecentProject(
            id: "apush",
            name: "APUSH",
            primaryPath: "/Users/veer/Documents/APUSH",
            matchingPathComponents: ["apush"]
        ),
        RecentProject(
            id: "bitwise",
            name: "Bitwise",
            primaryPath: "/Users/veer/Codex/Bitwise",
            matchingPathComponents: ["bitwise"]
        ),
        RecentProject(
            id: "droppy",
            name: "Droppy",
            primaryPath: "/Users/veer/Documents/Droppy Copy",
            matchingPathComponents: ["droppy", "droppy copy"]
        ),
    ]

    private static func recentProject(for path: String) -> RecentProject? {
        let components = Set(
            URL(fileURLWithPath: path).standardizedFileURL.pathComponents.map {
                $0.lowercased()
            }
        )
        return recentProjects.first {
            !$0.matchingPathComponents.isDisjoint(with: components)
        }
    }

    private static func groupMatchesQuery(
        _ group: CodexProjectGroup,
        query: String
    ) -> Bool {
        guard !query.isEmpty else { return true }
        if
            group.name.localizedCaseInsensitiveContains(query)
                || group.subtitle.localizedCaseInsensitiveContains(query)
        {
            return true
        }
        guard group.kind == .normalChats else { return false }
        return group.threads.contains {
            $0.projectName.localizedCaseInsensitiveContains(query)
                || $0.cwd.localizedCaseInsensitiveContains(query)
        }
    }

    var displayedThreads: [CodexThreadSummary] {
        let query = projectQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return threads }
        return threads.filter {
            $0.projectName.localizedCaseInsensitiveContains(query)
                || $0.cwd.localizedCaseInsensitiveContains(query)
        }
    }

    var availableProjects: [CodexProjectOption] {
        Self.recentProjects.map {
            CodexProjectOption(id: $0.id, name: $0.name, path: $0.primaryPath)
        }
    }

    func role(for threadID: String) -> CodexAgentRole? {
        roleAssignments[threadID] ?? handedOffRoleAssignments[threadID]
    }

    func isDroppyManaged(_ threadID: String) -> Bool {
        managedThreadIDs.contains(threadID)
    }

    func canSendReply(to thread: CodexThreadSummary) -> Bool {
        managedThreadIDs.contains(thread.id)
            && !thread.status.isActive
            && !isSending
            && !isHandingOff
            && !isTakingBack
    }

    func wasHandedOffToCodex(_ threadID: String) -> Bool {
        handedOffRoleAssignments[threadID] != nil
            && !managedThreadIDs.contains(threadID)
    }

    func canBringBackToDroppy(_ thread: CodexThreadSummary) -> Bool {
        wasHandedOffToCodex(thread.id)
            && !thread.status.isActive
            && !isSending
            && !isHandingOff
            && !isTakingBack
    }

    func openThread(id: String) {
        guard let thread = threads.first(where: { $0.id == id }) else { return }
        openThread(thread)
    }

    func openThread(_ thread: CodexThreadSummary) {
        let knownThread = applyingKnownModel(to: thread)
        lastIssue = nil
        selectedThread = knownThread
        loadThreadHistory(knownThread, clearExisting: true)
    }

    func refreshSelectedThreadHistory() {
        guard
            let selectedThread,
            !selectedThread.status.isActive,
            !isSending
        else { return }
        loadThreadHistory(selectedThread, clearExisting: false)
    }

    private func loadThreadHistory(
        _ thread: CodexThreadSummary,
        clearExisting: Bool,
        attempt: Int = 0,
        token existingToken: UUID? = nil
    ) {
        let token = existingToken ?? UUID()
        if attempt == 0 {
            if clearExisting { messages = [] }
            historyLoadToken = token
            isLoadingThread = clearExisting
        }
        client.request(
            method: "thread/read",
            params: ["threadId": thread.id, "includeTurns": true]
        ) { [weak self] result in
            guard let self, self.historyLoadToken == token else { return }
            switch result {
            case let .success(payload):
                self.isLoadingThread = false
                guard let value = payload["thread"] as? [String: Any] else {
                    self.lastIssue = CodexFeatureError.malformedResponse.localizedDescription
                    return
                }
                guard
                    let refreshedThread = Self.parseThread(value, model: thread.model),
                    refreshedThread.id == thread.id
                else {
                    self.lastIssue = CodexFeatureError.malformedResponse.localizedDescription
                    return
                }
                let currentStatus = self.threads.first(where: { $0.id == thread.id })?.status
                    ?? (self.selectedThread?.id == thread.id ? self.selectedThread?.status : nil)
                let displayedThread: CodexThreadSummary
                if
                    let currentStatus,
                    currentStatus.isActive,
                    !refreshedThread.status.isActive
                {
                    displayedThread = refreshedThread.replacing(status: currentStatus)
                } else {
                    displayedThread = refreshedThread
                }
                self.loadedHistoryDates[thread.id] = displayedThread.updatedAt
                if let index = self.threads.firstIndex(where: { $0.id == thread.id }) {
                    self.threads[index] = displayedThread
                }
                if self.selectedThread?.id == thread.id {
                    self.selectedThread = displayedThread
                    let parsedMessages = Self.parseMessages(from: value)
                    if
                        thread.status.isActive
                            || refreshedThread.status.isActive
                            || currentStatus?.isActive == true
                            || self.isSending
                    {
                        self.messages = Self.mergeHistoryMessages(
                            parsedMessages,
                            preservingLiveMessages: self.messages
                        )
                    } else {
                        self.messages = parsedMessages
                    }
                }
            case let .failure(error):
                if
                    attempt < 4,
                    Self.isTransientEmptyThreadReadError(error.localizedDescription)
                {
                    let delay = 0.15 * pow(2, Double(attempt))
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self, self.historyLoadToken == token else { return }
                        self.loadThreadHistory(
                            thread,
                            clearExisting: false,
                            attempt: attempt + 1,
                            token: token
                        )
                    }
                    return
                }
                self.isLoadingThread = false
                self.lastIssue = error.localizedDescription
            }
        }
    }

    func closeThread() {
        historyLoadToken = nil
        isLoadingThread = false
        selectedThread = nil
        messages = []
    }

    func createTask(
        prompt: String,
        projectPath: String,
        role: CodexAgentRole,
        attachments: [CodexDraftAttachment],
        completion: @escaping (Bool) -> Void
    ) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSending, !isHandingOff, !isTakingBack else {
            completion(false)
            return
        }
        guard !trimmedPrompt.isEmpty, projectPath.hasPrefix("/") else {
            lastIssue = "Choose a project folder and enter a task."
            completion(false)
            return
        }
        isSending = true
        lastIssue = nil
        client.request(
            method: "thread/start",
            params: Self.safeThreadStartParams(cwd: projectPath)
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(payload):
                guard
                    let thread = payload["thread"] as? [String: Any],
                    let summary = Self.parseThread(
                        thread,
                        model: payload["model"] as? String
                    )
                else {
                    self.isSending = false
                    self.lastIssue = CodexFeatureError.malformedResponse.localizedDescription
                    completion(false)
                    return
                }
                if let model = summary.model {
                    self.modelsByThreadID[summary.id] = model
                }
                self.assign(role: role, to: summary.id)
                let localMessageID = "droppy-local-\(UUID().uuidString)"
                let runningThread = summary.replacing(status: .running)
                if let index = self.threads.firstIndex(where: { $0.id == summary.id }) {
                    self.threads[index] = runningThread
                } else {
                    self.threads.insert(runningThread, at: 0)
                }
                self.selectedThread = runningThread
                self.messages = [
                    CodexChatMessage(
                        id: localMessageID,
                        sender: .user,
                        text: trimmedPrompt
                    )
                ]
                self.startTurn(
                    threadID: summary.id,
                    cwd: summary.cwd,
                    prompt: trimmedPrompt,
                    attachments: attachments,
                    threadToOpen: nil,
                    optimisticMessageID: localMessageID,
                    threadBeforeOptimisticStart: summary,
                    discardManagedThreadOnFailure: true,
                    completion: completion
                )
            case let .failure(error):
                self.isSending = false
                self.lastIssue = error.localizedDescription
                completion(false)
            }
        }
    }

    func sendReply(
        prompt: String,
        attachments: [CodexDraftAttachment],
        to thread: CodexThreadSummary,
        completion: ((Bool) -> Void)? = nil
    ) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSending, !isHandingOff, !isTakingBack else {
            completion?(false)
            return
        }
        guard managedThreadIDs.contains(thread.id) else {
            lastIssue = "This task is read-only in Silverdeck. Continue it in Codex."
            completion?(false)
            return
        }
        guard let currentThread = threads.first(where: { $0.id == thread.id })
            ?? (selectedThread?.id == thread.id ? selectedThread : nil)
        else {
            lastIssue = "Silverdeck could not find that task."
            completion?(false)
            return
        }
        guard !currentThread.status.isActive else {
            lastIssue = "Wait for the current response before sending another message."
            completion?(false)
            return
        }
        guard !trimmedPrompt.isEmpty else {
            completion?(false)
            return
        }

        isSending = true
        lastIssue = nil
        let sendTurn = { [weak self] (resumedThread: CodexThreadSummary) in
            guard let self else { return }
            guard !resumedThread.status.isActive else {
                self.isSending = false
                self.lastIssue = "This task is active in Codex. Wait for it to finish, then try again."
                completion?(false)
                return
            }
            let localMessageID = "droppy-local-\(UUID().uuidString)"
            self.messages.append(
                CodexChatMessage(id: localMessageID, sender: .user, text: trimmedPrompt)
            )
            let runningThread = resumedThread.replacing(status: .running)
            if let index = self.threads.firstIndex(where: { $0.id == resumedThread.id }) {
                self.threads[index] = runningThread
            }
            if self.selectedThread?.id == resumedThread.id {
                self.selectedThread = runningThread
            }
            self.startTurn(
                threadID: resumedThread.id,
                cwd: resumedThread.cwd,
                prompt: trimmedPrompt,
                attachments: attachments,
                threadToOpen: nil,
                optimisticMessageID: localMessageID,
                threadBeforeOptimisticStart: resumedThread,
                completion: completion
            )
        }

        if currentThread.status == .unavailable {
            resume(thread: currentThread, completion: sendTurn, failure: completion)
        } else {
            sendTurn(currentThread)
        }
    }

    func steerActiveTurn(
        prompt: String,
        threadID: String,
        completion: @escaping (Bool) -> Void
    ) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard managedThreadIDs.contains(threadID) else {
            lastIssue = "That task is no longer managed here."
            completion(false)
            return
        }
        guard let turnID = activeTurnIDsByThreadID[threadID] else {
            lastIssue = "The active Codex turn could not be found."
            completion(false)
            return
        }
        guard !trimmedPrompt.isEmpty else {
            completion(false)
            return
        }

        lastIssue = nil
        client.request(
            method: "turn/steer",
            params: [
                "threadId": threadID,
                "expectedTurnId": turnID,
                "input": Self.userInputs(prompt: trimmedPrompt, attachments: []),
            ]
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                if self.selectedThread?.id == threadID {
                    self.messages.append(
                        CodexChatMessage(
                            id: "droppy-local-\(UUID().uuidString)",
                            sender: .user,
                            text: trimmedPrompt
                        )
                    )
                }
                completion(true)
            case let .failure(error):
                self.lastIssue = error.localizedDescription
                completion(false)
            }
        }
    }

    func handOffToCodex(_ threadID: String) {
        guard managedThreadIDs.contains(threadID) else {
            openInCodex(threadID)
            return
        }
        guard !isHandingOff, !isTakingBack, !isSending else { return }
        guard let thread = threads.first(where: { $0.id == threadID })
            ?? (selectedThread?.id == threadID ? selectedThread : nil)
        else {
            lastIssue = "Silverdeck could not find that task."
            return
        }
        guard !thread.status.isRunning else {
            lastIssue = "Wait for the current response before handing this task to Codex."
            return
        }

        isHandingOff = true
        lastIssue = nil
        releaseSubscription(threadID: threadID) { [weak self] result in
            guard let self else { return }
            self.isHandingOff = false
            switch result {
            case .success:
                if let role = self.roleAssignments[threadID] {
                    self.setOwnership(.handedOff, role: role, threadID: threadID)
                }
                self.openInCodex(threadID)
                self.refresh()
            case let .failure(error):
                self.lastIssue = "Could not hand off this task: \(error.localizedDescription)"
            }
        }
    }

    func bringBackToDroppy(_ threadID: String) {
        guard
            !managedThreadIDs.contains(threadID),
            let role = handedOffRoleAssignments[threadID]
        else {
            lastIssue = "Only tasks previously handed off by Silverdeck can be brought back."
            return
        }
        guard !isTakingBack, !isHandingOff, !isSending else { return }
        guard let thread = threads.first(where: { $0.id == threadID })
            ?? (selectedThread?.id == threadID ? selectedThread : nil)
        else {
            lastIssue = "Silverdeck could not find that task."
            return
        }
        guard !thread.status.isActive else {
            lastIssue = "Wait for the current Codex response before bringing this task back."
            return
        }

        isTakingBack = true
        lastIssue = nil
        client.request(
            method: "thread/resume",
            params: Self.safeThreadResumeParams(threadID: threadID, cwd: thread.cwd)
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(payload):
                guard
                    let value = payload["thread"] as? [String: Any],
                    let resumed = Self.parseThread(value, model: payload["model"] as? String),
                    resumed.id == threadID
                else {
                    self.cancelTakeBackSubscription(
                        threadID: threadID,
                        message: CodexFeatureError.malformedResponse.localizedDescription,
                        role: role,
                        fallbackThread: thread
                    )
                    return
                }
                guard !resumed.status.isActive else {
                    self.cancelTakeBackSubscription(
                        threadID: threadID,
                        message: "This task is still active in Codex. Wait for it to finish, then bring it back.",
                        role: role,
                        fallbackThread: resumed
                    )
                    return
                }
                if let model = resumed.model {
                    self.modelsByThreadID[resumed.id] = model
                }
                self.setOwnership(.managed, role: role, threadID: threadID)
                self.isTakingBack = false
                if let index = self.threads.firstIndex(where: { $0.id == threadID }) {
                    self.threads[index] = resumed
                }
                self.openThread(resumed)
                self.refresh()
            case let .failure(error):
                self.isTakingBack = false
                self.lastIssue = "Could not bring this task back to Silverdeck: \(error.localizedDescription)"
            }
        }
    }

    private func cancelTakeBackSubscription(
        threadID: String,
        message: String,
        role: CodexAgentRole,
        fallbackThread: CodexThreadSummary
    ) {
        releaseSubscription(threadID: threadID) { [weak self] result in
            guard let self else { return }
            self.isTakingBack = false
            switch result {
            case .success:
                self.lastIssue = message
            case let .failure(error):
                self.setOwnership(.managed, role: role, threadID: threadID)
                if let index = self.threads.firstIndex(where: { $0.id == threadID }) {
                    self.threads[index] = fallbackThread
                }
                if self.selectedThread?.id == threadID {
                    self.selectedThread = fallbackThread
                }
                self.lastIssue = "\(message) Silverdeck could not release its temporary subscription, so it kept the task here safely: \(error.localizedDescription)"
            }
            self.refresh()
        }
    }

    private func releaseSubscription(
        threadID: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        client.request(
            method: "thread/unsubscribe",
            params: ["threadId": threadID]
        ) { result in
            switch result {
            case let .success(payload):
                let safeStatuses = Set(["notLoaded", "notSubscribed", "unsubscribed"])
                guard
                    let status = payload["status"] as? String,
                    safeStatuses.contains(status)
                else {
                    completion(.failure(CodexFeatureError.malformedResponse))
                    return
                }
                completion(.success(()))
            case let .failure(error):
                completion(.failure(error))
            }
        }
    }

    func openInCodex(_ threadID: String) {
        guard let url = URL(string: "codex://threads/\(threadID)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func startTurn(
        threadID: String,
        cwd: String,
        prompt: String,
        attachments: [CodexDraftAttachment],
        threadToOpen: CodexThreadSummary?,
        optimisticMessageID: String? = nil,
        threadBeforeOptimisticStart: CodexThreadSummary? = nil,
        discardManagedThreadOnFailure: Bool = false,
        completion: ((Bool) -> Void)? = nil
    ) {
        historyLoadToken = nil
        isLoadingThread = false
        client.request(
            method: "turn/start",
            params: Self.safeTurnStartParams(
                threadID: threadID,
                cwd: cwd,
                input: Self.userInputs(prompt: prompt, attachments: attachments)
            )
        ) { [weak self] result in
            guard let self else { return }
            self.isSending = false
            switch result {
            case let .success(payload):
                guard let turnID = Self.turnID(fromStartPayload: payload) else {
                    self.rollbackOptimisticTurn(
                        threadID: threadID,
                        optimisticMessageID: optimisticMessageID,
                        threadBeforeOptimisticStart: threadBeforeOptimisticStart,
                        discardManagedThreadOnFailure: discardManagedThreadOnFailure,
                        error: CodexFeatureError.malformedResponse,
                        completion: completion
                    )
                    return
                }
                self.activeTurnIDsByThreadID[threadID] = turnID
                let baseThread = threadToOpen
                    ?? self.threads.first(where: { $0.id == threadID })
                    ?? (self.selectedThread?.id == threadID ? self.selectedThread : nil)
                guard let baseThread else {
                    self.rollbackOptimisticTurn(
                        threadID: threadID,
                        optimisticMessageID: optimisticMessageID,
                        threadBeforeOptimisticStart: threadBeforeOptimisticStart,
                        discardManagedThreadOnFailure: discardManagedThreadOnFailure,
                        error: CodexFeatureError.malformedResponse,
                        completion: completion
                    )
                    return
                }
                let runningThread = baseThread.replacing(status: .running)
                if let index = self.threads.firstIndex(where: { $0.id == threadID }) {
                    self.threads[index] = runningThread
                }
                if self.selectedThread?.id == threadID {
                    self.selectedThread = runningThread
                }
                self.refresh()
                if threadToOpen != nil { self.openThread(runningThread) }
                completion?(true)
            case let .failure(error):
                self.rollbackOptimisticTurn(
                    threadID: threadID,
                    optimisticMessageID: optimisticMessageID,
                    threadBeforeOptimisticStart: threadBeforeOptimisticStart,
                    discardManagedThreadOnFailure: discardManagedThreadOnFailure,
                    error: error,
                    completion: completion
                )
            }
        }
    }

    private func rollbackOptimisticTurn(
        threadID: String,
        optimisticMessageID: String?,
        threadBeforeOptimisticStart: CodexThreadSummary?,
        discardManagedThreadOnFailure: Bool,
        error: Error,
        completion: ((Bool) -> Void)?
    ) {
        isSending = false
        if let optimisticMessageID {
            messages.removeAll { $0.id == optimisticMessageID }
        }
        if let threadBeforeOptimisticStart {
            if let index = threads.firstIndex(where: { $0.id == threadID }) {
                threads[index] = threadBeforeOptimisticStart
            }
            if selectedThread?.id == threadID {
                selectedThread = threadBeforeOptimisticStart
            }
        }
        if discardManagedThreadOnFailure {
            releaseFailedCreatedTask(
                threadID: threadID,
                error: error,
                fallbackThread: threadBeforeOptimisticStart,
                completion: completion
            )
            return
        }
        lastIssue = error.localizedDescription
        refresh()
        completion?(false)
    }

    private func releaseFailedCreatedTask(
        threadID: String,
        error: Error,
        fallbackThread: CodexThreadSummary?,
        completion: ((Bool) -> Void)?
    ) {
        isHandingOff = true
        releaseSubscription(threadID: threadID) { [weak self] result in
            guard let self else { return }
            self.isHandingOff = false
            switch result {
            case .success:
                self.clearOwnership(for: threadID)
                self.threads.removeAll { $0.id == threadID }
                if self.selectedThread?.id == threadID {
                    self.selectedThread = nil
                    self.messages = []
                }
                self.lastIssue = error.localizedDescription
            case let .failure(releaseError):
                if let role = self.roleAssignments[threadID] {
                    self.setOwnership(.managed, role: role, threadID: threadID)
                }
                if let fallbackThread {
                    let guardedThread = fallbackThread.replacing(status: .waiting)
                    if let index = self.threads.firstIndex(where: { $0.id == threadID }) {
                        self.threads[index] = guardedThread
                    }
                    if self.selectedThread?.id == threadID {
                        self.selectedThread = guardedThread
                    }
                }
                self.lastIssue = "\(error.localizedDescription) Silverdeck could not release the new task subscription, so it kept the task here safely: \(releaseError.localizedDescription)"
            }
            self.refresh()
            completion?(false)
        }
    }

    private func resume(
        thread: CodexThreadSummary,
        completion: @escaping (CodexThreadSummary) -> Void,
        failure: ((Bool) -> Void)?
    ) {
        guard let role = roleAssignments[thread.id] else {
            isSending = false
            lastIssue = "Silverdeck no longer owns this task. Open it in Codex to continue."
            failure?(false)
            return
        }
        client.request(
            method: "thread/resume",
            params: Self.safeThreadResumeParams(threadID: thread.id, cwd: thread.cwd)
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(payload):
                guard
                    let value = payload["thread"] as? [String: Any],
                    let resumed = Self.parseThread(value, model: payload["model"] as? String),
                    resumed.id == thread.id
                else {
                    self.cancelManagedResumeSubscription(
                        threadID: thread.id,
                        message: CodexFeatureError.malformedResponse.localizedDescription,
                        role: role,
                        fallbackThread: thread,
                        failure: failure
                    )
                    return
                }
                guard !resumed.status.isActive else {
                    self.cancelManagedResumeSubscription(
                        threadID: thread.id,
                        message: "This task is active in Codex. Wait for it to finish, then bring it back.",
                        role: role,
                        fallbackThread: resumed,
                        failure: failure
                    )
                    return
                }
                if let model = resumed.model { self.modelsByThreadID[resumed.id] = model }
                completion(resumed)
            case let .failure(error):
                self.isSending = false
                self.lastIssue = "Could not resume this task in Silverdeck: \(error.localizedDescription)"
                failure?(false)
            }
        }
    }

    private func cancelManagedResumeSubscription(
        threadID: String,
        message: String,
        role: CodexAgentRole,
        fallbackThread: CodexThreadSummary,
        failure: ((Bool) -> Void)?
    ) {
        releaseSubscription(threadID: threadID) { [weak self] result in
            guard let self else { return }
            self.isSending = false
            if let index = self.threads.firstIndex(where: { $0.id == threadID }) {
                self.threads[index] = fallbackThread
            }
            if self.selectedThread?.id == threadID {
                self.selectedThread = fallbackThread
            }
            switch result {
            case .success:
                self.setOwnership(.handedOff, role: role, threadID: threadID)
                self.lastIssue = message
            case let .failure(error):
                self.setOwnership(.managed, role: role, threadID: threadID)
                self.lastIssue = "\(message) Silverdeck could not release its temporary subscription, so it kept the task here safely: \(error.localizedDescription)"
            }
            self.refresh()
            failure?(false)
        }
    }

    private func refreshUsage() {
        client.request(method: "account/rateLimits/read") { [weak self] result in
            guard
                let self,
                case let .success(payload) = result,
                let limits = payload["rateLimits"] as? [String: Any],
                let primary = limits["primary"] as? [String: Any]
            else { return }
            guard let usedPercent = primary["usedPercent"] as? Int else { return }
            self.usagePercent = Self.remainingPercent(fromUsedPercent: usedPercent)
        }
    }

    private func scheduleRefreshes() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refreshTimer?.tolerance = 0.6
    }

    private func scheduleReconnect() {
        guard shouldReconnect, reconnectAttempt < 3, reconnectWorkItem == nil else { return }
        let delay = pow(2.0, Double(reconnectAttempt))
        reconnectAttempt += 1
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.reconnectWorkItem = nil
                self.connect()
            }
        }
        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func applyThreadList(_ newThreads: [CodexThreadSummary]) {
        threads = newThreads.map(applyingKnownModel)
        if let current = selectedThread {
            let selectedID = current.id
            let refreshed = threads.first(where: { $0.id == selectedID }) ?? current
            selectedThread = refreshed
            let lastLoaded = loadedHistoryDates[selectedID] ?? .distantPast
            if
                refreshed.updatedAt > lastLoaded,
                !isLoadingThread,
                !current.status.isActive,
                !refreshed.status.isActive,
                !isSending
            {
                loadThreadHistory(refreshed, clearExisting: false)
            }
        }
    }

    private func applyingKnownModel(to thread: CodexThreadSummary) -> CodexThreadSummary {
        guard thread.model == nil, let model = modelsByThreadID[thread.id] else { return thread }
        return thread.replacing(model: model)
    }

    private func pulseCompletion(for thread: CodexThreadSummary, turnID: String) {
        guard
            completedTurnIDs.insert(turnID).inserted,
            managedThreadIDs.contains(thread.id)
        else { return }

        completionClearWorkItems[thread.id]?.cancel()
        recentlyCompletedThreadIDs.insert(thread.id)

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.recentlyCompletedThreadIDs.remove(thread.id)
                self.completionClearWorkItems[thread.id] = nil
            }
        }
        completionClearWorkItems[thread.id] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }

    private func assign(role: CodexAgentRole, to threadID: String) {
        setOwnership(.managed, role: role, threadID: threadID)
    }

    private func setOwnership(
        _ state: OwnershipState,
        role: CodexAgentRole,
        threadID: String
    ) {
        ownershipRecords[threadID] = OwnershipRecord(state: state, role: role)
        roleAssignments[threadID] = state == .managed ? role : nil
        handedOffRoleAssignments[threadID] = state == .handedOff ? role : nil
        if state == .managed {
            managedThreadIDs.insert(threadID)
        } else {
            managedThreadIDs.remove(threadID)
        }
        persistOwnershipRecords()
    }

    private func clearOwnership(for threadID: String) {
        ownershipRecords[threadID] = nil
        roleAssignments[threadID] = nil
        handedOffRoleAssignments[threadID] = nil
        managedThreadIDs.remove(threadID)
        persistOwnershipRecords()
    }

    private func persistOwnershipRecords() {
        if let data = try? JSONEncoder().encode(ownershipRecords) {
            defaults.set(data, forKey: ownershipRecordsKey)
        }
    }

    private func handleNotification(method: String, params: [String: Any]) {
        switch method {
        case "thread/status/changed", "turn/started", "thread/started":
            refresh()
        case "turn/completed":
            guard let threadID = params["threadId"] as? String else { return }
            let turn = params["turn"] as? [String: Any]
            let status = turn?["status"] as? String
            activeTurnIDsByThreadID[threadID] = nil
            if
                selectedThread?.id == threadID,
                status == "failed" || status == "interrupted"
            {
                let fallback = status == "interrupted"
                    ? "The Codex turn was interrupted."
                    : "The Codex turn failed."
                lastIssue = Self.turnErrorMessage(from: turn) ?? fallback
            }
            if
                managedThreadIDs.contains(threadID),
                let turn,
                let turnID = turn["id"] as? String,
                status == "completed",
                let thread = threads.first(where: { $0.id == threadID })
                    ?? (selectedThread?.id == threadID ? selectedThread : nil)
            {
                pulseCompletion(for: thread, turnID: turnID)
            }
            if managedThreadIDs.contains(threadID), status == "completed" {
                let finalMessage = selectedThread?.id == threadID
                    ? messages.last(where: { $0.sender == .agent })?.text
                    : nil
                onManagedTurnCompleted?(threadID, finalMessage)
            }
            refresh()
            if selectedThread?.id == threadID { refreshSelectedThreadHistory() }
        case "error":
            let threadID = params["threadId"] as? String
            let willRetry = params["willRetry"] as? Bool ?? false
            if
                !willRetry,
                threadID == nil || selectedThread?.id == threadID,
                let message = Self.turnErrorMessage(from: params)
            {
                lastIssue = message
            }
        case "item/agentMessage/delta":
            guard
                let threadID = params["threadId"] as? String,
                managedThreadIDs.contains(threadID),
                selectedThread?.id == threadID,
                selectedThread?.status.isRunning == true,
                let itemID = params["itemId"] as? String,
                let delta = params["delta"] as? String
            else { return }
            if let index = messages.firstIndex(where: { $0.id == itemID }) {
                messages[index].text += delta
            } else {
                messages.append(CodexChatMessage(id: itemID, sender: .agent, text: delta))
            }
        default:
            break
        }
    }

    static func mergeHistoryMessages(
        _ history: [CodexChatMessage],
        preservingLiveMessages live: [CodexChatMessage]
    ) -> [CodexChatMessage] {
        let liveByID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
        var merged = history.map { message -> CodexChatMessage in
            guard
                let liveMessage = liveByID[message.id],
                liveMessage.sender == message.sender,
                liveMessage.text.count >= message.text.count,
                liveMessage.text.hasPrefix(message.text)
            else { return message }
            return liveMessage
        }
        let historyIDs = Set(history.map(\.id))
        merged.append(contentsOf: live.filter { !historyIDs.contains($0.id) })
        return merged
    }

    static func turnErrorMessage(from value: [String: Any]?) -> String? {
        guard let value else { return nil }
        if let error = value["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty
        {
            return message
        }
        if let message = value["message"] as? String, !message.isEmpty {
            return message
        }
        return nil
    }

    static func turnID(fromStartPayload payload: [String: Any]) -> String? {
        guard
            let turn = payload["turn"] as? [String: Any],
            let turnID = turn["id"] as? String,
            !turnID.isEmpty
        else { return nil }
        return turnID
    }

    private func handleProtectedRequest(
        requestID: Int,
        method: String,
        params: [String: Any]
    ) {
        guard
            let threadID = params["threadId"] as? String,
            managedThreadIDs.contains(threadID)
        else {
            rejectProtectedRequest(requestID: requestID, method: method)
            return
        }

        if let userInput = Self.userInputRequest(
            requestID: requestID,
            method: method,
            params: params
        ) {
            pendingUserInputs.removeAll { $0.id == requestID }
            pendingUserInputs.append(userInput)
            lastIssue = nil
            if selectedThread?.id == threadID, let selectedThread {
                self.selectedThread = selectedThread.replacing(status: .waiting)
            }
            onApprovalNeeded?()
            return
        }

        guard let approval = Self.approvalRequest(
            requestID: requestID,
            method: method,
            params: params
        ) else {
            rejectProtectedRequest(requestID: requestID, method: method)
            lastIssue = "Codex requested additional input that Command Mode cannot present yet. Silverdeck cancelled that request safely."
            return
        }

        pendingApprovals.removeAll { $0.id == requestID }
        pendingApprovals.append(approval)
        lastIssue = nil
        if selectedThread?.id == threadID, let selectedThread {
            self.selectedThread = selectedThread.replacing(status: .waiting)
        }
        onApprovalNeeded?()
    }

    func respondToUserInput(id: Int, answers: [String: [String]]) {
        guard pendingUserInputs.contains(where: { $0.id == id }) else { return }
        let payload = Self.userInputResponse(answers: answers)
        pendingUserInputs.removeAll { $0.id == id }
        client.respondToServerRequest(id: id, result: payload)
        refresh()
    }

    func cancelUserInput(id: Int) {
        respondToUserInput(id: id, answers: [:])
    }

    func respondToApproval(id: Int, approved: Bool) {
        guard let approval = pendingApprovals.first(where: { $0.id == id }) else {
            return
        }
        let result = Self.approvalResponse(for: approval, approved: approved)
        pendingApprovals.removeAll { $0.id == id }
        client.respondToServerRequest(id: id, result: result)
        refresh()
    }

    static func approvalResponse(
        for approval: CodexApprovalRequest,
        approved: Bool
    ) -> [String: Any] {
        switch approval.kind {
        case .command, .fileChange:
            return ["decision": approved ? "accept" : "decline"]
        case .permissions:
            return [
                "permissions": approved ? (approval.requestedPermissions ?? [:]) : [:],
                "scope": "turn",
            ]
        }
    }

    static func approvalRequest(
        requestID: Int,
        method: String,
        params: [String: Any]
    ) -> CodexApprovalRequest? {
        guard let threadID = params["threadId"] as? String else { return nil }
        let reason = (params["reason"] as? String)?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        switch method {
        case "item/commandExecution/requestApproval":
            let command = params["command"] as? String
            let cwd = params["cwd"] as? String
            let available = params["availableDecisions"] as? [Any]
            let allowsAccept = available?.contains {
                ($0 as? String) == "accept"
            } ?? true
            let detail = [reason, cwd.map { "Working directory: \($0)" }]
                .compactMap { $0 }
                .joined(separator: "\n")
            return CodexApprovalRequest(
                id: requestID,
                kind: .command,
                threadID: threadID,
                title: "Allow this command?",
                detail: detail.isEmpty ? "Codex wants to run a shell command." : detail,
                command: command,
                requestedPermissions: nil,
                canApprove: allowsAccept
            )

        case "item/fileChange/requestApproval":
            let grantRoot = params["grantRoot"] as? String
            let detail = [reason, grantRoot.map { "Write access: \($0)" }]
                .compactMap { $0 }
                .joined(separator: "\n")
            return CodexApprovalRequest(
                id: requestID,
                kind: .fileChange,
                threadID: threadID,
                title: "Allow these file changes?",
                detail: detail.isEmpty
                    ? "Codex wants to modify files in the selected project."
                    : detail,
                command: nil,
                requestedPermissions: nil,
                canApprove: true
            )

        case "item/permissions/requestApproval":
            let permissions = params["permissions"] as? [String: Any] ?? [:]
            let cwd = params["cwd"] as? String
            let summary = permissionSummary(permissions)
            let detail = [reason, cwd.map { "Working directory: \($0)" }, summary]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            return CodexApprovalRequest(
                id: requestID,
                kind: .permissions,
                threadID: threadID,
                title: "Allow additional access?",
                detail: detail,
                command: nil,
                requestedPermissions: permissions,
                canApprove: true
            )

        default:
            return nil
        }
    }

    static func userInputRequest(
        requestID: Int,
        method: String,
        params: [String: Any]
    ) -> CodexUserInputRequest? {
        guard
            method == "item/tool/requestUserInput" || method == "tool/requestUserInput",
            let threadID = params["threadId"] as? String,
            let rawQuestions = params["questions"] as? [[String: Any]],
            !rawQuestions.isEmpty
        else { return nil }

        let questions = rawQuestions.compactMap { value -> CodexUserInputQuestion? in
            guard
                let id = value["id"] as? String,
                !id.isEmpty,
                let header = value["header"] as? String,
                let question = value["question"] as? String,
                !question.isEmpty
            else { return nil }
            let options = (value["options"] as? [[String: Any]] ?? []).compactMap {
                option -> CodexUserInputOption? in
                guard let label = option["label"] as? String, !label.isEmpty else {
                    return nil
                }
                return CodexUserInputOption(
                    label: label,
                    description: option["description"] as? String ?? ""
                )
            }
            return CodexUserInputQuestion(
                id: id,
                header: header,
                question: question,
                isOther: value["isOther"] as? Bool ?? false,
                isSecret: value["isSecret"] as? Bool ?? false,
                options: options
            )
        }
        guard questions.count == rawQuestions.count else { return nil }
        return CodexUserInputRequest(
            id: requestID,
            threadID: threadID,
            questions: questions
        )
    }

    static func userInputResponse(answers: [String: [String]]) -> [String: Any] {
        [
            "answers": answers.mapValues { ["answers": $0] },
        ]
    }

    private static func permissionSummary(_ permissions: [String: Any]) -> String? {
        guard
            JSONSerialization.isValidJSONObject(permissions),
            let data = try? JSONSerialization.data(
                withJSONObject: permissions,
                options: [.prettyPrinted, .sortedKeys]
            )
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func rejectProtectedRequest(requestID: Int, method: String) {
        if let result = CodexAppServerClient.safeRejectionResult(for: method) {
            client.respondToServerRequest(id: requestID, result: result)
        } else {
            client.rejectServerRequest(
                id: requestID,
                message: "This request must be handled in Codex."
            )
        }
    }

    static func safeThreadStartParams(cwd: String) -> [String: Any] {
        [
            "cwd": cwd,
            "approvalPolicy": "on-request",
            "sandbox": "workspace-write",
            "serviceName": "mission_control",
        ]
    }

    static func safeThreadResumeParams(threadID: String, cwd: String) -> [String: Any] {
        [
            "threadId": threadID,
            "cwd": cwd,
            "approvalPolicy": "on-request",
            "sandbox": "workspace-write",
        ]
    }

    static func safeTurnStartParams(
        threadID: String,
        cwd: String,
        input: [[String: Any]]
    ) -> [String: Any] {
        [
            "threadId": threadID,
            "cwd": cwd,
            "input": input,
            "approvalPolicy": "on-request",
            "sandboxPolicy": [
                "type": "workspaceWrite",
                "writableRoots": [cwd],
                "networkAccess": false,
            ],
        ]
    }

    static func parseThread(
        _ value: [String: Any],
        model: String? = nil
    ) -> CodexThreadSummary? {
        guard
            let id = value["id"] as? String,
            let cwd = value["cwd"] as? String
        else { return nil }
        let name = (value["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = value["preview"] as? String ?? ""
        let title = name?.isEmpty == false ? name! : preview.firstLine.fallback("Untitled task")
        let timestamp = (value["recencyAt"] as? NSNumber)?.doubleValue
            ?? (value["updatedAt"] as? NSNumber)?.doubleValue
            ?? 0
        return CodexThreadSummary(
            id: id,
            title: title,
            preview: preview,
            cwd: cwd,
            status: parseStatus(value["status"] as? [String: Any]),
            model: model ?? value["model"] as? String,
            updatedAt: Date(timeIntervalSince1970: timestamp)
        )
    }

    static func remainingPercent(fromUsedPercent usedPercent: Int) -> Int {
        max(0, min(100, 100 - usedPercent))
    }

    static func isTransientEmptyThreadReadError(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("failed to read session metadata")
            && normalized.contains("is empty")
    }

    static func parseStatus(_ value: [String: Any]?) -> CodexRuntimeStatus {
        guard let type = value?["type"] as? String else { return .unavailable }
        switch type {
        case "active":
            let flags = value?["activeFlags"] as? [String] ?? []
            return flags.isEmpty ? .running : .waiting
        case "idle": return .idle
        case "systemError": return .failed
        default: return .unavailable
        }
    }

    static func parseMessages(from thread: [String: Any]) -> [CodexChatMessage] {
        let turns = thread["turns"] as? [[String: Any]] ?? []
        return turns.flatMap { turn -> [CodexChatMessage] in
            let items = turn["items"] as? [[String: Any]] ?? []
            return items.compactMap { item in
                guard let id = item["id"] as? String, let type = item["type"] as? String else {
                    return nil
                }
                if type == "agentMessage", let text = item["text"] as? String {
                    return CodexChatMessage(id: id, sender: .agent, text: text)
                }
                if type == "userMessage" {
                    let content = item["content"] as? [[String: Any]] ?? []
                    let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
                    return text.isEmpty ? nil : CodexChatMessage(id: id, sender: .user, text: text)
                }
                return nil
            }
        }
    }

    static func userInputs(
        prompt: String,
        attachments: [CodexDraftAttachment]
    ) -> [[String: Any]] {
        let files = attachments.filter { !$0.isImage }
        let fileText = files.isEmpty
            ? ""
            : "\n\nLocal files to review:\n" + files.map { "- \($0.url.path)" }.joined(separator: "\n")
        var inputs: [[String: Any]] = [["type": "text", "text": prompt + fileText]]
        inputs.append(contentsOf: attachments.filter(\.isImage).map {
            ["type": "localImage", "path": $0.url.path]
        })
        return inputs
    }
}

private extension String {
    var firstLine: String {
        components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    func fallback(_ value: String) -> String {
        isEmpty ? value : self
    }
}
