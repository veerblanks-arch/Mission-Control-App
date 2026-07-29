import AppKit
import Combine
import Darwin
import SwiftTerm
import SwiftUI

enum TerminalSessionState: Equatable {
    case ready
    case running
    case stopping
    case failedToStop
    case exited(Int32?)

    var isRunning: Bool {
        self == .running
    }

    var hasLiveProcess: Bool {
        self == .running || self == .stopping || self == .failedToStop
    }
}

struct TerminalProcessIdentity: Hashable {
    let pid: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

enum TerminalProcessTree {
    static func childPIDs(of parentPID: pid_t) -> [pid_t] {
        let capacity = max(Int(proc_listchildpids(parentPID, nil, 0)), 16)
        var children = [pid_t](repeating: 0, count: capacity)
        let count = children.withUnsafeMutableBytes { buffer in
            proc_listchildpids(
                parentPID,
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        guard count > 0 else {
            return []
        }
        return Array(children.prefix(Int(count))).filter { $0 > 0 }
    }

    static func descendantPIDs(of rootPID: pid_t) -> [pid_t] {
        var visited = Set<pid_t>()
        var descendants: [pid_t] = []
        var pending = childPIDs(of: rootPID)
        while let pid = pending.popLast() {
            guard visited.insert(pid).inserted else {
                continue
            }
            descendants.append(pid)
            pending.append(contentsOf: childPIDs(of: pid))
        }
        return descendants
    }

    static func signalTree(rootPID: pid_t, signal signalNumber: Int32) {
        guard rootPID > 0 else {
            return
        }
        let processIDs = Set(descendantPIDs(of: rootPID) + [rootPID])
        signal(
            processIDs: processIDs,
            rootPID: rootPID,
            signal: signalNumber
        )
    }

    static func signal(
        processIDs: Set<pid_t>,
        rootPID: pid_t,
        signal signalNumber: Int32
    ) {
        for pid in processIDs where pid > 0 && pid != rootPID {
            _ = Darwin.kill(pid, signalNumber)
        }
        if rootPID > 0 {
            _ = Darwin.kill(-rootPID, signalNumber)
            _ = Darwin.kill(rootPID, signalNumber)
        }
    }

    static func identities(
        for processIDs: some Sequence<pid_t>
    ) -> Set<TerminalProcessIdentity> {
        Set(processIDs.compactMap(identity(for:)))
    }

    static func identity(for pid: pid_t) -> TerminalProcessIdentity? {
        guard pid > 0 else {
            return nil
        }
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let result = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(size)
        )
        guard result == Int32(size) else {
            return nil
        }
        return TerminalProcessIdentity(
            pid: pid,
            startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec
        )
    }

    static func isAlive(_ identity: TerminalProcessIdentity) -> Bool {
        self.identity(for: identity.pid) == identity
    }

    static func signal(
        processes: Set<TerminalProcessIdentity>,
        rootPID: pid_t,
        signal signalNumber: Int32
    ) {
        for process in processes
        where process.pid != rootPID && isAlive(process) {
            _ = Darwin.kill(process.pid, signalNumber)
        }
        guard
            let root = processes.first(where: { $0.pid == rootPID }),
            isAlive(root)
        else {
            return
        }
        _ = Darwin.kill(-rootPID, signalNumber)
        _ = Darwin.kill(rootPID, signalNumber)
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else {
            return false
        }
        return Darwin.kill(pid, 0) == 0 || errno == EPERM
    }
}

@MainActor
final class TerminalSessionController: NSObject, ObservableObject,
    LocalProcessTerminalViewDelegate, Identifiable
{
    let id: UUID
    @Published private(set) var terminalView: LocalProcessTerminalView
    @Published private(set) var terminalGeneration = UUID()

    @Published private(set) var title: String
    @Published private(set) var currentDirectoryURL: URL
    @Published private(set) var state: TerminalSessionState = .ready

    private var hasStarted = false
    private var shouldRestartAfterExit = false
    private var stopGeneration = 0
    private var stopCompletions: [(Bool) -> Void] = []
    private var stoppingProcesses = Set<TerminalProcessIdentity>()
    private var stoppingRootPID: pid_t = 0
    private var stoppingRootIdentity: TerminalProcessIdentity?

    init(
        id: UUID = UUID(),
        currentDirectoryURL: URL,
        title: String? = nil
    ) {
        self.id = id
        self.currentDirectoryURL = currentDirectoryURL.standardizedFileURL
        self.title = title ?? currentDirectoryURL.lastPathComponent
        terminalView = LocalProcessTerminalView(frame: .zero)
        super.init()
        terminalView.processDelegate = self
    }

    func startIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        state = .running
        terminalView.startProcess(
            executable: "/bin/zsh",
            args: ["-l"],
            environment: nil,
            execName: "-zsh",
            currentDirectory: currentDirectoryURL.path
        )
    }

    func sendInterrupt() {
        guard state.isRunning else { return }
        let interrupt = [UInt8(3)]
        terminalView.send(
            source: terminalView,
            data: interrupt[interrupt.startIndex...]
        )
    }

    func clear() {
        guard state.isRunning else { return }
        sendCommand("clear")
    }

    func sendCommand(_ command: String) {
        guard state.isRunning else { return }
        let command = Array("\(command)\n".utf8)
        terminalView.send(
            source: terminalView,
            data: command[command.startIndex...]
        )
    }

    func restart() {
        if state.hasLiveProcess {
            requestStop(restartAfterExit: true)
        } else {
            restartProcess()
        }
    }

    func terminate(completion: ((Bool) -> Void)? = nil) {
        requestStop(
            restartAfterExit: false,
            completion: completion
        )
    }

    func updateDirectory(_ url: URL) {
        let normalized = url.standardizedFileURL
        currentDirectoryURL = normalized
        title = normalized.lastPathComponent
        restart()
    }

    nonisolated func sizeChanged(
        source: LocalProcessTerminalView,
        newCols: Int,
        newRows: Int
    ) {}

    nonisolated func setTerminalTitle(
        source: LocalProcessTerminalView,
        title: String
    ) {
        Task { @MainActor [weak self] in
            guard let self, source === self.terminalView else { return }
            let trimmed = title.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !trimmed.isEmpty else { return }
            self.title = trimmed
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(
        source: TerminalView,
        directory: String?
    ) {
        Task { @MainActor [weak self] in
            guard let self, source === self.terminalView else { return }
            guard let directory, !directory.isEmpty else { return }
            let path: String
            if let url = URL(string: directory), url.isFileURL {
                path = url.path
            } else {
                path = directory
            }
            self.currentDirectoryURL = URL(
                fileURLWithPath: path,
                isDirectory: true
            ).standardizedFileURL
        }
    }

    nonisolated func processTerminated(
        source: TerminalView,
        exitCode: Int32?
    ) {
        Task { @MainActor [weak self] in
            guard
                let self,
                source === terminalView
            else {
                return
            }
            handleProcessTerminated(exitCode: exitCode)
        }
    }

    private func requestStop(
        restartAfterExit: Bool,
        completion: ((Bool) -> Void)? = nil
    ) {
        shouldRestartAfterExit = restartAfterExit
        if let completion {
            stopCompletions.append(completion)
        }
        guard state.hasLiveProcess else {
            finishStop(exitCode: nil)
            return
        }
        guard state != .stopping else {
            return
        }

        let isRetry = state == .failedToStop
        state = .stopping
        stopGeneration += 1
        let generation = stopGeneration
        if !isRetry {
            stoppingRootPID = terminalView.process.shellPid
            stoppingRootIdentity = TerminalProcessTree.identity(
                for: stoppingRootPID
            )
            stoppingProcesses = Set(
                [stoppingRootIdentity].compactMap { $0 }
            )
        }
        refreshStoppingDescendants()
        TerminalProcessTree.signal(
            processes: stoppingProcesses,
            rootPID: stoppingRootPID,
            signal: SIGTERM
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard
                let self,
                generation == stopGeneration,
                state == .stopping
            else {
                return
            }
            refreshStoppingDescendants()
            TerminalProcessTree.signal(
                processes: stoppingProcesses,
                rootPID: stoppingRootPID,
                signal: SIGKILL
            )
            DispatchQueue.main.asyncAfter(
                deadline: .now() + 0.25
            ) { [weak self] in
                guard
                    let self,
                    generation == stopGeneration,
                    state == .stopping
                else {
                    return
                }
                finishForcedStop(
                    processes: stoppingProcesses,
                    rootPID: stoppingRootPID,
                    generation: generation,
                    exitCode: nil,
                    deadline: Date().addingTimeInterval(3)
                )
            }
        }
    }

    private func refreshStoppingDescendants() {
        guard
            let rootIdentity = stoppingRootIdentity,
            TerminalProcessTree.isAlive(rootIdentity)
        else {
            return
        }
        let childProcessIDs = TerminalProcessTree.descendantPIDs(
            of: rootIdentity.pid
        )
        guard TerminalProcessTree.isAlive(rootIdentity) else {
            return
        }
        stoppingProcesses.formUnion(
            TerminalProcessTree.identities(for: childProcessIDs)
        )
    }

    private func handleProcessTerminated(exitCode: Int32?) {
        guard state == .stopping else {
            finishStop(exitCode: exitCode)
            return
        }
        finishForcedStop(
            processes: stoppingProcesses,
            rootPID: stoppingRootPID,
            generation: stopGeneration,
            exitCode: exitCode,
            deadline: Date().addingTimeInterval(3)
        )
    }

    private func finishForcedStop(
        processes: Set<TerminalProcessIdentity>,
        rootPID: pid_t,
        generation: Int,
        exitCode: Int32?,
        deadline: Date
    ) {
        guard
            generation == stopGeneration,
            state == .stopping
        else {
            return
        }

        if
            !terminalView.process.running,
            let rootIdentity = stoppingRootIdentity,
            TerminalProcessTree.isAlive(rootIdentity)
        {
            var status: Int32 = 0
            _ = waitpid(rootIdentity.pid, &status, WNOHANG)
        }
        let livingProcesses = processes.filter(
            TerminalProcessTree.isAlive
        )
        if livingProcesses.isEmpty && !terminalView.process.running {
            finishStop(exitCode: exitCode)
            return
        }
        guard Date() < deadline else {
            finishStop(exitCode: exitCode, succeeded: false)
            return
        }

        if !livingProcesses.isEmpty {
            TerminalProcessTree.signal(
                processes: Set(livingProcesses),
                rootPID: rootPID,
                signal: SIGKILL
            )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            [weak self] in
            self?.finishForcedStop(
                processes: processes,
                rootPID: rootPID,
                generation: generation,
                exitCode: exitCode,
                deadline: deadline
            )
        }
    }

    private func finishStop(
        exitCode: Int32?,
        succeeded: Bool = true
    ) {
        stopGeneration += 1
        if succeeded {
            stoppingProcesses.removeAll()
            stoppingRootPID = 0
            stoppingRootIdentity = nil
            state = .exited(exitCode)
        } else {
            state = .failedToStop
        }
        let completions = stopCompletions
        stopCompletions.removeAll()
        completions.forEach { $0(succeeded) }

        if succeeded && shouldRestartAfterExit {
            shouldRestartAfterExit = false
            restartProcess()
        } else if !succeeded {
            shouldRestartAfterExit = false
        }
    }

    private func restartProcess() {
        terminalView.processDelegate = nil
        let replacement = LocalProcessTerminalView(frame: .zero)
        replacement.processDelegate = self
        terminalView = replacement
        terminalGeneration = UUID()
        state = .ready
        hasStarted = false
        startIfNeeded()
    }
}

@MainActor
final class TerminalFeature: ObservableObject {
    static let shared = TerminalFeature()

    @Published private(set) var sessions: [TerminalSessionController] = []
    @Published var selectedSessionID: UUID?
    private var closingSessions: [UUID: TerminalSessionController] = [:]

    var selectedSession: TerminalSessionController? {
        sessions.first { $0.id == selectedSessionID }
    }

    var hasRunningSessions: Bool {
        sessions.contains { $0.state.hasLiveProcess }
            || closingSessions.values.contains {
                $0.state.hasLiveProcess
            }
    }

    var runningSessionCount: Int {
        sessions.filter { $0.state.hasLiveProcess }.count
            + closingSessions.values.filter {
                $0.state.hasLiveProcess
            }.count
    }

    @discardableResult
    func newSession(
        currentDirectoryURL: URL = FileManager.default
            .homeDirectoryForCurrentUser
    ) -> TerminalSessionController {
        let session = TerminalSessionController(
            currentDirectoryURL: currentDirectoryURL
        )
        sessions.append(session)
        selectedSessionID = session.id
        return session
    }

    func ensureSession(currentDirectoryURL: URL) {
        guard sessions.isEmpty else { return }
        newSession(currentDirectoryURL: currentDirectoryURL)
    }

    func close(_ session: TerminalSessionController) {
        sessions.removeAll { $0.id == session.id }
        if selectedSessionID == session.id {
            selectedSessionID = sessions.first?.id
        }
        guard session.state.hasLiveProcess else {
            return
        }
        closingSessions[session.id] = session
        session.terminate { [weak self, weak session] stopped in
            guard let session else { return }
            if stopped {
                self?.closingSessions[session.id] = nil
            }
        }
    }

    func stopAll(completion: ((Bool) -> Void)? = nil) {
        let targets = Array(
            Dictionary(
                uniqueKeysWithValues:
                    (sessions + Array(closingSessions.values))
                    .map { ($0.id, $0) }
            ).values
        ).filter { $0.state.hasLiveProcess }
        guard !targets.isEmpty else {
            completion?(true)
            return
        }

        var remaining = targets.count
        var allStopped = true
        targets.forEach { session in
            session.terminate { stopped in
                allStopped = allStopped && stopped
                remaining -= 1
                if remaining == 0 {
                    completion?(allStopped)
                }
            }
        }
    }

    func openSelectedDirectoryInAppleTerminal() {
        guard let directoryURL = selectedSession?.currentDirectoryURL else {
            return
        }
        let terminalURL = URL(
            fileURLWithPath: "/System/Applications/Utilities/Terminal.app",
            isDirectory: true
        )
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [directoryURL],
            withApplicationAt: terminalURL,
            configuration: configuration
        )
    }
}

struct TerminalFeatureView: View {
    @ObservedObject var feature: TerminalFeature
    let defaultDirectoryURL: URL

    var body: some View {
        VStack(spacing: 0) {
            sessionBar
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

            Divider()

            if let session = feature.selectedSession {
                TerminalSessionView(session: session, feature: feature)
            } else {
                emptyState
            }
        }
        .onAppear {
            feature.ensureSession(currentDirectoryURL: defaultDirectoryURL)
        }
    }

    private var sessionBar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(feature.sessions) { session in
                        TerminalSessionTab(
                            session: session,
                            isSelected: feature.selectedSessionID == session.id
                        ) {
                            feature.selectedSessionID = session.id
                        }
                    }
                }
            }

            Button {
                feature.newSession(
                    currentDirectoryURL: feature.selectedSession?
                        .currentDirectoryURL ?? defaultDirectoryURL
                )
            } label: {
                Image(systemName: "plus")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("New terminal")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "terminal")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(.secondary)
            Button("New Terminal") {
                feature.newSession(currentDirectoryURL: defaultDirectoryURL)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TerminalSessionTab: View {
    @ObservedObject var session: TerminalSessionController
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(session.title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: 110)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                isSelected ? Color.accentColor.opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
        }
        .buttonStyle(.plain)
    }

    private var statusColor: SwiftUI.Color {
        switch session.state {
        case .running:
            return .green
        case .stopping:
            return .orange
        case .failedToStop:
            return .red
        case .ready, .exited:
            return .secondary
        }
    }
}

private struct TerminalSessionView: View {
    @ObservedObject var session: TerminalSessionController
    @ObservedObject var feature: TerminalFeature

    var body: some View {
        VStack(spacing: 0) {
            controls
                .padding(.horizontal, 10)
                .padding(.vertical, 7)

            Divider()

            TerminalViewRepresentable(session: session)
                .id(session.terminalGeneration)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                chooseDirectory()
            } label: {
                Label(
                    session.currentDirectoryURL.lastPathComponent,
                    systemImage: "folder"
                )
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("Change working directory")

            Spacer()

            Button {
                session.sendInterrupt()
            } label: {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.plain)
            .help("Send Control-C")
            .disabled(!session.state.isRunning)

            Button {
                session.restart()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Restart shell")

            Button {
                session.clear()
            } label: {
                Image(systemName: "eraser")
            }
            .buttonStyle(.plain)
            .help("Clear terminal")
            .disabled(!session.state.isRunning)

            Button {
                feature.openSelectedDirectoryInAppleTerminal()
            } label: {
                Image(systemName: "macwindow")
            }
            .buttonStyle(.plain)
            .help("Open in Terminal")

            Button {
                closeSession()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Close terminal")
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose a working directory"
        panel.prompt = "Choose"
        panel.directoryURL = session.currentDirectoryURL
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        session.updateDirectory(url)
    }

    private func closeSession() {
        if session.state.hasLiveProcess {
            let alert = NSAlert()
            alert.messageText = "Close this terminal?"
            alert.informativeText =
                "Its shell and any command running inside it will stop."
            alert.addButton(withTitle: "Close Terminal")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                return
            }
        }
        feature.close(session)
    }
}

private struct TerminalViewRepresentable: NSViewRepresentable {
    @ObservedObject var session: TerminalSessionController

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        session.startIfNeeded()
        DispatchQueue.main.async {
            session.terminalView.window?.makeFirstResponder(
                session.terminalView
            )
        }
        return session.terminalView
    }

    func updateNSView(
        _ nsView: LocalProcessTerminalView,
        context: Context
    ) {}
}
