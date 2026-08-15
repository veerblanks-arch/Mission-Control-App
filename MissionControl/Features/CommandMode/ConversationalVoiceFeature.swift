import Foundation

@MainActor
final class ConversationalVoiceFeature: ObservableObject {
    @Published private(set) var state: ConversationalVoiceState = .idle
    @Published private(set) var transcript: [VoiceTranscriptEntry] = []
    @Published private(set) var liveUserTranscript = ""
    @Published private(set) var liveAssistantTranscript = ""
    @Published private(set) var activeCodexThreadID: String?

    var onUserRequest: ((String) -> Void)?
    var onListeningRequested: (() -> Void)?
    var onListeningCancelled: (() -> Void)?
    var onHardInterruptRequested: ((String) -> Void)?
    var onShowSettings: (() -> Void)?

    private let speechOutput: CodexSpeechOutput
    private var sessionActive = false
    private var responseFinished = false

    init() {
        self.speechOutput = CodexSpeechOutput()
        speechOutput.onSpeakingChanged = { [weak self] speaking in
            self?.handleSpeakingChanged(speaking)
        }
    }

    init(speechOutput: CodexSpeechOutput) {
        self.speechOutput = speechOutput
        speechOutput.onSpeakingChanged = { [weak self] speaking in
            self?.handleSpeakingChanged(speaking)
        }
    }

    var isSessionActive: Bool { sessionActive }

    func prepareForPresentation() {
        stop()
        transcript = []
        liveUserTranscript = ""
        liveAssistantTranscript = ""
        activeCodexThreadID = nil
    }

    func start(projectNames _: [String]) {
        guard !sessionActive else { return }
        sessionActive = true
        responseFinished = false
        state = .requestingMicrophone
        onListeningRequested?()
    }

    func stop() {
        sessionActive = false
        responseFinished = false
        onListeningCancelled?()
        speechOutput.stop()
        state = .idle
        liveUserTranscript = ""
        liveAssistantTranscript = ""
    }

    func toggle(projectNames: [String]) {
        if sessionActive {
            stop()
        } else {
            start(projectNames: projectNames)
        }
    }

    func handleVoiceState(_ voiceState: CommandVoiceState) {
        guard sessionActive else { return }
        switch voiceState {
        case .requestingPermission:
            state = .requestingMicrophone
        case .listening:
            if state != .speaking { state = .listening }
        case let .unavailable(message):
            speechOutput.stop()
            sessionActive = false
            state = .failed(message)
        case .idle:
            break
        }
    }

    func receivePartialTranscript(_ text: String) {
        guard sessionActive else { return }
        let normalized = CommandVoiceTranscriptNormalizer.normalize(text)
        guard !normalized.isEmpty else { return }

        if state == .speaking {
            if CodexVoicePrompt.isLikelyPlaybackEcho(
                normalized,
                assistantText: liveAssistantTranscript
            ) {
                return
            }
            speechOutput.stop()
            finalizeAssistantTranscript()
            state = .listening
        }
        liveUserTranscript = normalized
    }

    func receiveFinalTranscript(_ text: String) {
        guard sessionActive else { return }
        let normalized = CommandVoiceTranscriptNormalizer.normalize(text)
        guard !normalized.isEmpty else {
            requestListening()
            return
        }
        if state == .speaking,
           CodexVoicePrompt.isLikelyPlaybackEcho(
               normalized,
               assistantText: liveAssistantTranscript
           )
        {
            liveUserTranscript = ""
            requestListening()
            return
        }
        sendText(normalized)
    }

    func sendText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sessionActive, !trimmed.isEmpty else { return }

        speechOutput.stop()
        if !liveAssistantTranscript.isEmpty {
            finalizeAssistantTranscript()
        }
        liveUserTranscript = ""
        appendTranscript(.user, text: trimmed)
        responseFinished = false
        state = .thinking

        if CodexVoicePrompt.isStopRequest(trimmed), let threadID = activeCodexThreadID {
            onHardInterruptRequested?(threadID)
        } else {
            onUserRequest?(trimmed)
        }
    }

    func setActiveCodexThread(_ threadID: String?) {
        activeCodexThreadID = threadID
    }

    func receiveCodexDelta(threadID: String, delta: String) {
        guard
            sessionActive,
            threadID == activeCodexThreadID,
            !delta.isEmpty
        else { return }
        liveAssistantTranscript += delta
        speechOutput.append(delta)
        if state != .speaking { state = .thinking }
    }

    func notifyCodexCompleted(threadID: String, result: String?) {
        guard sessionActive, threadID == activeCodexThreadID else { return }
        if liveAssistantTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let result,
           !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            liveAssistantTranscript = result
            speechOutput.append(result)
        }
        responseFinished = true
        speechOutput.finish()
        if !speechOutput.isSpeaking {
            finishResponseAndListen()
        }
    }

    func notifyCodexInterrupted(threadID: String) {
        guard sessionActive, threadID == activeCodexThreadID else { return }
        speechOutput.stop()
        finalizeAssistantTranscript()
        responseFinished = false
        appendTranscript(.system, text: "Codex stopped the current response.")
        requestListening()
    }

    func notifyCodexFailed(threadID: String, message: String) {
        guard sessionActive, threadID == activeCodexThreadID else { return }
        speechOutput.stop()
        finalizeAssistantTranscript()
        responseFinished = false
        state = .failed(message)
    }

    func deliverLocalResponse(_ message: String, succeeded: Bool) {
        guard sessionActive else { return }
        let fallback = succeeded ? "Done." : "I couldn't complete that."
        let response = message.trimmingCharacters(in: .whitespacesAndNewlines)
        liveAssistantTranscript = response.isEmpty ? fallback : response
        responseFinished = true
        speechOutput.append(liveAssistantTranscript)
        speechOutput.finish()
        if !speechOutput.isSpeaking {
            finishResponseAndListen()
        }
    }

    func interruptAndListen() {
        guard sessionActive else { return }
        speechOutput.stop()
        finalizeAssistantTranscript()
        responseFinished = false
        if let threadID = activeCodexThreadID {
            onHardInterruptRequested?(threadID)
        } else {
            requestListening()
        }
    }

    func showSettings() {
        onShowSettings?()
    }

    private func handleSpeakingChanged(_ speaking: Bool) {
        guard sessionActive else { return }
        if speaking {
            state = .speaking
            // Keep transcription active during playback so a new utterance can
            // stop local speech and steer the in-flight Codex turn.
            onListeningRequested?()
        } else if responseFinished {
            finishResponseAndListen()
        } else if state == .speaking {
            state = .thinking
        }
    }

    private func finishResponseAndListen() {
        finalizeAssistantTranscript()
        responseFinished = false
        requestListening()
    }

    private func requestListening() {
        guard sessionActive else { return }
        liveUserTranscript = ""
        state = .listening
        onListeningRequested?()
    }

    private func finalizeAssistantTranscript() {
        let text = liveAssistantTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { appendTranscript(.assistant, text: text) }
        liveAssistantTranscript = ""
    }

    private func appendTranscript(_ speaker: VoiceTranscriptSpeaker, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        transcript.append(VoiceTranscriptEntry(speaker: speaker, text: trimmed))
        if transcript.count > 40 {
            transcript.removeFirst(transcript.count - 40)
        }
    }
}
