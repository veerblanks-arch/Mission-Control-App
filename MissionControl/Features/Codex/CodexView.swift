import AppKit
import SwiftUI

struct CodexView: View {
    @ObservedObject var feature: CodexFeature
    @State private var isCreatingTask = false
    @State private var expandedProjectPaths: Set<String> = []

    var body: some View {
        Group {
            if let thread = feature.selectedThread {
                chatView(thread)
            } else {
                dashboard
            }
        }
        .sheet(isPresented: $isCreatingTask) {
            CodexNewTaskView(feature: feature, isPresented: $isCreatingTask)
        }
        .onAppear { feature.refresh() }
    }

    private var dashboard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "folder.badge.magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter by project", text: $feature.projectQuery)
                    .textFieldStyle(.plain)

                if let usage = feature.usagePercent {
                    Text("\(usage)%")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .help("Codex usage remaining")
                }

                Button {
                    isCreatingTask = true
                } label: {
                    Label("New Task", systemImage: "square.and.pencil")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(14)

            Divider()

            if case let .failed(message) = feature.connectionState {
                unavailableState(message)
            } else if feature.displayedProjectGroups.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(feature.displayedProjectGroups) { project in
                            CodexProjectSection(
                                project: project,
                                isExpanded: expandedProjectPaths.contains(project.id),
                                role: feature.role(for:),
                                isRecentlyCompleted: feature.recentlyCompletedThreadIDs.contains,
                                onToggle: { toggleProject(project.id) },
                                onOpenThread: feature.openThread(_:)
                            )
                        }
                    }
                    .padding(14)
                }
            }
        }
    }

    private func chatView(_ thread: CodexThreadSummary) -> some View {
        CodexChatView(feature: feature, thread: thread)
    }

    private func toggleProject(_ path: String) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if expandedProjectPaths.contains(path) {
                expandedProjectPaths.remove(path)
            } else {
                expandedProjectPaths.insert(path)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(feature.projectQuery.isEmpty ? "No Codex tasks found" : "No matching projects")
                .font(.system(size: 15, weight: .semibold))
            Text("Create a task or change the project filter.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func unavailableState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.orange)
            Text("Codex is unavailable")
                .font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again") { feature.start() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

private struct CodexProjectSection: View {
    let project: CodexProjectGroup
    let isExpanded: Bool
    let role: (String) -> CodexAgentRole?
    let isRecentlyCompleted: (String) -> Bool
    let onToggle: () -> Void
    let onOpenThread: (CodexThreadSummary) -> Void

    var body: some View {
        VStack(spacing: 6) {
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Image(systemName: "folder.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(project.subtitle)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("\(project.threads.count) \(project.threads.count == 1 ? "chat" : "chats")")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .contentShape(Rectangle())
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)

            if isExpanded {
                LazyVStack(spacing: 6) {
                    ForEach(project.threads) { thread in
                        Button {
                            onOpenThread(thread)
                        } label: {
                            CodexThreadRow(
                                thread: thread,
                                role: role(thread.id),
                                showsSourceProject: project.kind == .normalChats,
                                isRecentlyCompleted: isRecentlyCompleted(thread.id)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 18)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

private struct CodexThreadRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let thread: CodexThreadSummary
    let role: CodexAgentRole?
    let showsSourceProject: Bool
    let isRecentlyCompleted: Bool

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if isRecentlyCompleted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.green)
                } else if let role {
                    CodexPetIcon(role: role, size: 25)
                } else {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(
                            thread.status == .failed ? Color.red : Color.accentColor
                        )
                }
            }
            .frame(width: 30, height: 30)
            .background(
                (isRecentlyCompleted ? Color.green : Color.accentColor).opacity(0.1),
                in: RoundedRectangle(cornerRadius: 7)
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(thread.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if showsSourceProject {
                        Text(thread.projectName)
                        Text("•")
                    }
                    Text(thread.status.title)
                    if let role {
                        Text("•")
                        Text(role.title)
                    }
                    if let model = thread.model {
                        Text("•")
                        Text(model)
                    }
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                Text(thread.preview)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 9).fill(.thinMaterial)
            if isRecentlyCompleted {
                RoundedRectangle(cornerRadius: 9).fill(Color.green.opacity(0.14))
            }
        }
        .overlay {
            if isRecentlyCompleted {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(Color.green.opacity(0.65), lineWidth: 1)
            }
        }
        .scaleEffect(isRecentlyCompleted && !reduceMotion ? 1.015 : 1)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.72), value: isRecentlyCompleted)
    }
}

private struct CodexPetIcon: View {
    let role: CodexAgentRole
    let size: CGFloat

    var body: some View {
        if
            let url = Bundle.main.url(
                forResource: role.petAssetName,
                withExtension: "png"
            ),
            let image = NSImage(contentsOf: url)
        {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityLabel("\(role.title) Codex pet")
        } else {
            Image(systemName: role.symbolName)
                .font(.system(size: size * 0.62, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: size, height: size)
        }
    }
}

private struct CodexChatView: View {
    @ObservedObject var feature: CodexFeature
    let thread: CodexThreadSummary
    @State private var reply = ""
    @State private var attachments: [CodexDraftAttachment] = []

    var body: some View {
        let isDroppyManaged = feature.isDroppyManaged(thread.id)
        let wasHandedOff = feature.wasHandedOffToCodex(thread.id)
        let isDroppyActive = isDroppyManaged && thread.status.isActive
        let isRecentlyCompleted = feature.recentlyCompletedThreadIDs.contains(thread.id)

        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { feature.closeThread() } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .help("Back to Codex tasks")

                if let role = feature.role(for: thread.id) {
                    CodexPetIcon(role: role, size: 24)
                        .help(role.title)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(thread.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text("\(thread.projectName) • \(thread.status.title)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 6) {
                    if let model = thread.model {
                        Text(model)
                    }
                    if let usage = feature.usagePercent {
                        if thread.model != nil { Text("•") }
                        Text("\(usage)%")
                            .help("Codex usage remaining")
                    }
                }
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)

                Button {
                    feature.refreshSelectedThreadHistory()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(thread.status.isActive || feature.isSending)
                .help("Refresh saved history")

                Button {
                    if isDroppyManaged {
                        feature.handOffToCodex(thread.id)
                    } else if wasHandedOff {
                        feature.bringBackToDroppy(thread.id)
                    } else {
                        feature.openInCodex(thread.id)
                    }
                } label: {
                    Label(
                        isDroppyManaged
                            ? "Hand Off"
                            : wasHandedOff ? "Bring Back" : "Open in Codex",
                        systemImage: wasHandedOff
                            ? "arrow.down.backward.circle"
                            : "arrow.up.forward.app"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(
                    isDroppyManaged
                        && (
                            thread.status.isRunning
                                || feature.isHandingOff
                                || feature.isTakingBack
                                || feature.isSending
                        )
                        || wasHandedOff
                        && (
                            thread.status.isActive
                                || feature.isTakingBack
                                || feature.isHandingOff
                                || feature.isSending
                        )
                )
                .help(
                    isDroppyManaged
                        ? thread.status.isRunning
                            ? "Wait for the current response before handing this task to Codex"
                            : "Release Mission Control's live session and continue this task in Codex"
                        : wasHandedOff
                        ? thread.status.isActive
                            ? "Wait for the current Codex response before bringing this task back"
                            : "Resume this same task as a live Mission Control chat"
                        : "Open this saved task in Codex"
                )
            }
            .padding(12)

            Divider()

            HStack(spacing: 8) {
                Image(systemName: isRecentlyCompleted ? "checkmark.circle.fill" : "info.circle.fill")
                Text(
                    isRecentlyCompleted
                        ? "This chat just finished. You can reply below or hand it off to Codex."
                        : isDroppyManaged && thread.status == .waiting
                        ? "Mission Control cancelled a protected request. Hand off to Codex to review and continue."
                        : wasHandedOff && thread.status == .waiting
                        ? "This task still needs attention in Codex. Bring it back after that request is resolved."
                        : thread.status == .waiting
                        ? "This saved task needs attention in Codex. Open it there to continue."
                        : isDroppyActive
                        ? "Live in Mission Control. The current response is streaming into this chat."
                        : isDroppyManaged
                        ? "Live Mission Control chat. Reply below, or hand it off to continue in Codex."
                        : wasHandedOff
                        ? "Handed off to Codex. Bring it back to continue this same task in Mission Control."
                        : "Saved history only. Open in Codex to continue this task."
                )
                Spacer()
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(isRecentlyCompleted ? Color.green : Color.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                (isRecentlyCompleted ? Color.green : Color.accentColor).opacity(0.08)
            )
            .animation(.easeInOut(duration: 0.2), value: isRecentlyCompleted)

            Divider()

            if feature.isLoadingThread {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(feature.messages) { message in
                                CodexMessageBubble(message: message)
                                    .id(message.id)
                            }
                        }
                        .padding(14)
                    }
                    .onChange(of: feature.messages) {
                        if let last = feature.messages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            if isDroppyManaged {
                Divider()
                CodexComposer(
                    text: $reply,
                    attachments: $attachments,
                    isSending: feature.isSending || thread.status.isActive || feature.isHandingOff,
                    sendTitle: thread.status == .waiting
                        ? "Needs Attention"
                        : thread.status.isRunning ? "Running" : "Send"
                ) {
                    feature.sendReply(
                        prompt: reply,
                        attachments: attachments,
                        to: thread
                    ) { succeeded in
                        if succeeded {
                            reply = ""
                            attachments = []
                        }
                    }
                }
            }

            if let issue = feature.lastIssue {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(issue)
                        .font(.system(size: 10))
                    Spacer()
                    Button(
                        isDroppyManaged
                            ? "Hand Off"
                            : wasHandedOff ? "Bring Back" : "Open in Codex"
                    ) {
                        if isDroppyManaged {
                            feature.handOffToCodex(thread.id)
                        } else if wasHandedOff {
                            feature.bringBackToDroppy(thread.id)
                        } else {
                            feature.openInCodex(thread.id)
                        }
                    }
                        .buttonStyle(.link)
                        .disabled(
                            feature.isHandingOff
                                || feature.isTakingBack
                                || feature.isSending
                                || (isDroppyManaged && thread.status.isRunning)
                                || (wasHandedOff && thread.status.isActive)
                        )
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.orange.opacity(0.08))
            }
        }
    }
}

private struct CodexMessageBubble: View {
    let message: CodexChatMessage

    var body: some View {
        HStack {
            if message.sender == .user { Spacer(minLength: 42) }
            Text(message.text)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(
                    message.sender == .user
                        ? Color.accentColor.opacity(0.16)
                        : Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 10)
                )
            if message.sender == .agent { Spacer(minLength: 42) }
        }
    }
}

private struct CodexComposer: View {
    @Binding var text: String
    @Binding var attachments: [CodexDraftAttachment]
    let isSending: Bool
    let sendTitle: String
    let onSend: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(attachments) { attachment in
                            HStack(spacing: 5) {
                                Image(systemName: attachment.isImage ? "photo" : "doc")
                                Text(attachment.url.lastPathComponent).lineLimit(1)
                                Button {
                                    attachments.removeAll { $0.id == attachment.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                            }
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                        }
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button { chooseAttachments() } label: {
                    Image(systemName: "paperclip")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .help("Attach files")

                TextEditor(text: $text)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 38, maxHeight: 76)
                    .padding(5)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))

                Button(sendTitle) { onSend() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
            }
        }
        .padding(10)
        .dropDestination(for: URL.self) { urls, _ in
            append(urls)
            return !urls.isEmpty
        }
    }

    private func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        append(panel.urls)
    }

    private func append(_ urls: [URL]) {
        let existing = Set(attachments.map { $0.url.standardizedFileURL })
        attachments.append(contentsOf: urls
            .map(\.standardizedFileURL)
            .filter { !existing.contains($0) }
            .map(CodexDraftAttachment.init(url:)))
    }
}

private struct CodexNewTaskView: View {
    @ObservedObject var feature: CodexFeature
    @Binding var isPresented: Bool
    @State private var prompt = ""
    @State private var projectPath: String
    @State private var role: CodexAgentRole = .planner
    @State private var attachments: [CodexDraftAttachment] = []

    init(feature: CodexFeature, isPresented: Binding<Bool>) {
        self.feature = feature
        _isPresented = isPresented
        _projectPath = State(initialValue: feature.availableProjects.first?.path ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("New Codex Task")
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Button { isPresented = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Project").font(.system(size: 11, weight: .semibold))
                HStack {
                    Picker("", selection: $projectPath) {
                        if projectPath.isEmpty { Text("Choose a project").tag("") }
                        ForEach(feature.availableProjects) { project in
                            Text(project.name).tag(project.path)
                        }
                    }
                    .labelsHidden()
                    Button("Choose Folder…") { chooseProject() }
                }
                if !projectPath.isEmpty {
                    Text(projectPath)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Task label").font(.system(size: 11, weight: .semibold))
                Picker("Task label", selection: $role) {
                    ForEach(CodexAgentRole.allCases) { role in
                        Label(role.title, systemImage: role.symbolName).tag(role)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                HStack(spacing: 8) {
                    CodexPetIcon(role: role, size: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(role.title)
                            .font(.system(size: 10, weight: .semibold))
                        Text("Visual label for organizing this task")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Text("Mission Control keeps this chat live. Hand it off to Codex whenever you want.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            CodexComposer(
                text: $prompt,
                attachments: $attachments,
                isSending: feature.isSending,
                sendTitle: "Create"
            ) {
                feature.createTask(
                    prompt: prompt,
                    projectPath: projectPath,
                    role: role,
                    attachments: attachments
                ) { succeeded in
                    if succeeded { isPresented = false }
                }
            }

            if let issue = feature.lastIssue {
                Text(issue)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(18)
        .frame(width: 520, height: 390)
    }

    private func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        projectPath = url.standardizedFileURL.path
    }
}
