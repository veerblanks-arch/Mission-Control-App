import AppKit
import SwiftUI

struct CommandModeView: View {
    @ObservedObject var feature: CommandModeFeature
    @ObservedObject private var conversation: ConversationalVoiceFeature
    @ObservedObject private var codex: CodexFeature
    let onDismiss: () -> Void
    @FocusState private var isCommandFieldFocused: Bool

    init(feature: CommandModeFeature, onDismiss: @escaping () -> Void) {
        self.feature = feature
        _conversation = ObservedObject(wrappedValue: feature.conversation)
        _codex = ObservedObject(wrappedValue: CodexFeature.shared)
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(spacing: 0) {
            commandBar

            Divider()

            if let approval = codex.pendingApprovals.first {
                approvalCard(approval)
            } else if let request = codex.pendingUserInputs.first {
                CodexUserInputCard(feature: codex, request: request)
            } else if showsConversation {
                conversationView
            } else if !feature.choices.isEmpty {
                choiceList
            } else {
                suggestionList
            }

            statusBar
        }
        .frame(width: 680, height: 470)
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 32, y: 18)
        .onAppear(perform: focusCommandField)
        .onChange(of: feature.presentationID) { _, _ in
            focusCommandField()
        }
    }

    private var commandBar: some View {
        HStack(spacing: 14) {
            commandCore

            VStack(alignment: .leading, spacing: 5) {
                TextField(
                    conversation.isSessionActive ? "Talk or type a follow-up…" : "Ask Silverdeck…",
                    text: $feature.query
                )
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .semibold))
                    .focused($isCommandFieldFocused)
                    .onSubmit(feature.submit)
                    .disabled(hasPendingCodexInteraction)

                Text("Open things instantly. Complex requests become Codex tasks.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button(action: feature.toggleVoice) {
                Image(systemName: conversation.isSessionActive ? "stop.fill" : "mic.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(conversation.isSessionActive ? Color.orange : .primary)
                    .frame(width: 30, height: 30)
                    .background(
                        conversation.isSessionActive
                            ? Color.orange.opacity(0.16)
                            : Color.white.opacity(0.06),
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .help(conversation.isSessionActive ? "End voice conversation" : "Start voice conversation")
            .disabled(hasPendingCodexInteraction)

            Text("⇧⌘Space")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var commandCore: some View {
        if
            let url = Bundle.main.url(
                forResource: "mission-control-core",
                withExtension: "png"
            ),
            let image = NSImage(contentsOf: url)
        {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 50, height: 50)
                .clipShape(Circle())
                .overlay {
                    Circle().strokeBorder(.orange.opacity(0.7), lineWidth: 1)
                }
                .accessibilityLabel("Silverdeck command core")
        } else {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
        }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(feature.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "QUICK COMMANDS"
                : "SILVERDECK WILL")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.top, 14)

            ForEach(feature.suggestions) { suggestion in
                commandRow(suggestion)
            }

            Spacer(minLength: 0)
        }
    }

    private var choiceList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CHOOSE A TARGET")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.top, 14)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(feature.choices) { choice in
                        Button {
                            feature.execute(choice.resolution)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: choice.symbolName)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.orange)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(choice.title)
                                        .font(.system(size: 13, weight: .semibold))
                                        .lineLimit(1)
                                    Text(choice.subtitle)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "return")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                    }
                }
                .padding(.horizontal, 12)
            }

            Spacer(minLength: 0)
        }
    }

    private var conversationView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("CONVERSATION")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                if conversation.activeCodexThreadID != nil {
                    Label("Codex connected", systemImage: "sparkles")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 13)
            .padding(.bottom, 8)

            if conversation.state == .needsAPIKey {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Connect OpenAI Realtime", systemImage: "key.fill")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Add your OpenAI API key in Settings. It is stored in this Mac’s Keychain and is never shown in the command window.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button("Open Settings") {
                        conversation.showSettings()
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .padding(16)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 18)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 9) {
                        ForEach(conversation.transcript) { entry in
                            transcriptRow(entry)
                        }
                        if !conversation.liveUserTranscript.isEmpty {
                            transcriptRow(
                                VoiceTranscriptEntry(
                                    speaker: .user,
                                    text: conversation.liveUserTranscript
                                ),
                                isLive: true
                            )
                        }
                        if !conversation.liveAssistantTranscript.isEmpty {
                            transcriptRow(
                                VoiceTranscriptEntry(
                                    speaker: .assistant,
                                    text: conversation.liveAssistantTranscript
                                ),
                                isLive: true
                            )
                        }
                        if conversation.transcript.isEmpty
                            && conversation.liveUserTranscript.isEmpty
                            && conversation.liveAssistantTranscript.isEmpty
                        {
                            Text("I’m listening. Ask naturally, interrupt me, or tell me to open something or start work in a project.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private func transcriptRow(
        _ entry: VoiceTranscriptEntry,
        isLive: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: transcriptSymbol(entry.speaker))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(entry.speaker == .assistant ? Color.orange : .secondary)
                .frame(width: 15, height: 17)
            Text(entry.text)
                .font(.system(size: 12, weight: isLive ? .medium : .regular))
                .foregroundStyle(entry.speaker == .system ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func transcriptSymbol(_ speaker: VoiceTranscriptSpeaker) -> String {
        switch speaker {
        case .user: return "person.fill"
        case .assistant: return "waveform"
        case .system: return "sparkles"
        }
    }

    private func approvalCard(_ approval: CodexApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: approvalSymbol(for: approval.kind))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(approval.title)
                        .font(.system(size: 16, weight: .semibold))
                    Text("Codex is waiting for your decision")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            if !approval.detail.isEmpty {
                Text(approval.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(5)
            }

            if let command = approval.command, !command.isEmpty {
                ScrollView(.horizontal) {
                    Text(command)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                }
                .background(.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8))
            }

            Spacer(minLength: 0)

            HStack {
                Text("Approval applies once. Silverdeck does not remember it.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Deny") {
                    codex.respondToApproval(id: approval.id, approved: false)
                }

                Button("Allow Once") {
                    codex.respondToApproval(id: approval.id, approved: true)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!approval.canApprove)
            }
        }
        .padding(18)
    }

    private func approvalSymbol(for kind: CodexApprovalKind) -> String {
        switch kind {
        case .command: return "terminal"
        case .fileChange: return "doc.badge.gearshape"
        case .permissions: return "lock.open.trianglebadge.exclamationmark"
        }
    }

    private func commandRow(_ suggestion: CommandResolution) -> some View {
        Button {
            feature.fill(suggestion)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: suggestion.symbolName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(suggestion.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "return")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private var statusBar: some View {
        if !codex.pendingApprovals.isEmpty {
            status(
                "Review the exact request before allowing it.",
                symbol: "exclamationmark.shield.fill",
                color: .orange
            )
        } else if !codex.pendingUserInputs.isEmpty {
            status(
                "Codex needs a choice before it can continue.",
                symbol: "questionmark.bubble.fill",
                color: .orange
            )
        } else {
            voiceStatusBar
        }
    }

    @ViewBuilder
    private var voiceStatusBar: some View {
        switch conversation.state {
        case .requestingMicrophone:
            status("Requesting microphone access…", symbol: "mic", color: .orange)
        case .connecting:
            status("Connecting to OpenAI Realtime…", symbol: "network", color: .orange)
        case .listening:
            status("Listening — speak naturally or interrupt the response.", symbol: "waveform", color: .orange)
        case .thinking:
            status("Thinking…", symbol: "ellipsis.bubble.fill", color: .orange)
        case .speaking:
            status("Speaking — start talking to interrupt.", symbol: "speaker.wave.2.fill", color: .orange)
        case let .working(message):
            status(message, symbol: "gearshape.2.fill", color: .orange)
        case .needsAPIKey:
            status("An OpenAI API key is required for conversational voice.", symbol: "key.fill", color: .orange)
        case let .failed(message):
            status(message, symbol: "exclamationmark.triangle.fill", color: .orange)
        case .idle:
            executionStatusBar
        }
    }

    @ViewBuilder
    private var executionStatusBar: some View {
        switch feature.executionState {
        case .idle:
            HStack {
                Text("⇧⌘Space to speak · Return to type")
                Spacer()
                Text("Conversational voice · Esc to close")
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(.black.opacity(0.12))

        case let .working(message):
            status(message, symbol: "progress.indicator", color: .orange)
        case let .succeeded(message):
            status(message, symbol: "checkmark.circle.fill", color: .green)
        case let .failed(message):
            status(message, symbol: "exclamationmark.triangle.fill", color: .orange)
        }
    }

    private func status(_ message: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            Text(message)
                .lineLimit(2)
            Spacer()
        }
        .font(.system(size: 10, weight: .medium))
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(.black.opacity(0.12))
    }

    private func focusCommandField() {
        DispatchQueue.main.async {
            isCommandFieldFocused = true
        }
    }

    private var hasPendingCodexInteraction: Bool {
        !codex.pendingApprovals.isEmpty || !codex.pendingUserInputs.isEmpty
    }

    private var showsConversation: Bool {
        conversation.state != .idle
            || !conversation.transcript.isEmpty
            || !conversation.liveUserTranscript.isEmpty
            || !conversation.liveAssistantTranscript.isEmpty
    }
}

private struct CodexUserInputCard: View {
    @ObservedObject var feature: CodexFeature
    let request: CodexUserInputRequest
    @State private var selections: [String: String] = [:]
    @State private var customAnswers: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex needs your input")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Answer here without opening the chat")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(request.questions) { question in
                        questionView(question)
                    }
                }
            }

            HStack {
                Button("Cancel Request") {
                    feature.cancelUserInput(id: request.id)
                }

                Spacer()

                Button("Send Answer") {
                    feature.respondToUserInput(
                        id: request.id,
                        answers: resolvedAnswers
                    )
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!hasCompleteAnswers)
            }
        }
        .padding(18)
    }

    @ViewBuilder
    private func questionView(_ question: CodexUserInputQuestion) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(question.header.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
            Text(question.question)
                .font(.system(size: 12, weight: .semibold))

            if !question.options.isEmpty {
                Picker(
                    question.header,
                    selection: selectionBinding(for: question.id)
                ) {
                    Text("Choose…").tag("")
                    ForEach(question.options) { option in
                        Text(option.label).tag(option.label)
                    }
                    if question.isOther {
                        Text("Other…").tag(otherToken)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            if question.options.isEmpty
                || selections[question.id] == otherToken
            {
                if question.isSecret {
                    SecureField(
                        "Your answer",
                        text: customAnswerBinding(for: question.id)
                    )
                    .textFieldStyle(.roundedBorder)
                } else {
                    TextField(
                        "Your answer",
                        text: customAnswerBinding(for: question.id)
                    )
                    .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private var resolvedAnswers: [String: [String]] {
        Dictionary(uniqueKeysWithValues: request.questions.compactMap { question in
            let selected = selections[question.id] ?? ""
            let answer = selected == otherToken || question.options.isEmpty
                ? (customAnswers[question.id] ?? "")
                : selected
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : (question.id, [trimmed])
        })
    }

    private var hasCompleteAnswers: Bool {
        resolvedAnswers.count == request.questions.count
    }

    private var otherToken: String { "__mission_control_other__" }

    private func selectionBinding(for id: String) -> Binding<String> {
        Binding(
            get: { selections[id] ?? "" },
            set: { selections[id] = $0 }
        )
    }

    private func customAnswerBinding(for id: String) -> Binding<String> {
        Binding(
            get: { customAnswers[id] ?? "" },
            set: { customAnswers[id] = $0 }
        )
    }
}
