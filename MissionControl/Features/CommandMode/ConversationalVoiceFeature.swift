import AVFoundation
import Foundation

@MainActor
final class ConversationalVoiceFeature: ObservableObject {
    typealias ToolCompletion = ([String: Any]) -> Void

    @Published private(set) var state: ConversationalVoiceState = .idle
    @Published private(set) var transcript: [VoiceTranscriptEntry] = []
    @Published private(set) var liveUserTranscript = ""
    @Published private(set) var liveAssistantTranscript = ""
    @Published private(set) var activeCodexThreadID: String?

    var onLocalAction: ((String, @escaping ToolCompletion) -> Void)?
    var onStartCodexTask: ((String, String?, @escaping ToolCompletion) -> Void)?
    var onContinueCodexTask: ((String, @escaping ToolCompletion) -> Void)?
    var onShowSettings: (() -> Void)?

    private let client: RealtimeVoiceClient
    private let keyStore: RealtimeAPIKeyStore
    private var sessionGeneration = UUID()

    init(
        client: RealtimeVoiceClient = RealtimeVoiceClient(),
        keyStore: RealtimeAPIKeyStore = RealtimeAPIKeyStore()
    ) {
        self.client = client
        self.keyStore = keyStore
        client.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        client.onDisconnect = { [weak self] message in
            Task { @MainActor in self?.handleDisconnect(message) }
        }
    }

    var isSessionActive: Bool { state.isSessionActive }

    func prepareForPresentation() {
        stop()
        transcript = []
        liveUserTranscript = ""
        liveAssistantTranscript = ""
        activeCodexThreadID = nil
    }

    func start(projectNames: [String]) {
        guard !state.isSessionActive else { return }
        let apiKey: String
        do {
            guard let savedKey = try keyStore.load() else {
                state = .needsAPIKey
                return
            }
            apiKey = savedKey
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        let generation = UUID()
        sessionGeneration = generation
        state = .requestingMicrophone
        requestMicrophoneAccess { [weak self] allowed in
            guard let self, self.sessionGeneration == generation else { return }
            guard allowed else {
                self.state = .failed(
                    "Microphone access is off. Enable it in System Settings > Privacy & Security > Microphone."
                )
                return
            }
            self.state = .connecting
            self.client.connect(
                apiKey: apiKey,
                sessionUpdate: ConversationalVoiceSessionBuilder.sessionUpdate(
                    projectNames: projectNames
                )
            )
        }
    }

    func stop() {
        sessionGeneration = UUID()
        client.disconnect()
        state = .idle
        liveUserTranscript = ""
        liveAssistantTranscript = ""
    }

    func toggle(projectNames: [String]) {
        if state.isSessionActive {
            stop()
        } else {
            start(projectNames: projectNames)
        }
    }

    func sendText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if state.isSessionActive {
            appendTranscript(.user, text: trimmed)
            state = .thinking
            client.sendText(trimmed)
        }
    }

    func setActiveCodexThread(_ threadID: String?) {
        activeCodexThreadID = threadID
    }

    func notifyCodexCompleted(threadID: String, result: String?) {
        guard
            threadID == activeCodexThreadID,
            state.isSessionActive
        else { return }
        let summary = String(
            (result?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? result!
                : "The Codex task finished without a text summary.")
                .prefix(4_000)
        )
        appendTranscript(.system, text: "Codex finished: \(summary)")
        state = .thinking
        client.injectSystemUpdate(
            summary,
            responseInstructions: "Tell the user that Codex finished. Summarize the result in one or two useful sentences, then ask whether they want a follow-up."
        )
    }

    func showSettings() {
        onShowSettings?()
    }

    private func requestMicrophoneAccess(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { allowed in
                DispatchQueue.main.async { completion(allowed) }
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    private func handle(_ event: [String: Any]) {
        let type = event["type"] as? String ?? ""
        switch type {
        case "session.updated":
            state = .listening

        case "input_audio_buffer.speech_started":
            liveUserTranscript = ""
            liveAssistantTranscript = ""
            state = .listening

        case "input_audio_buffer.speech_stopped":
            state = .thinking

        case "conversation.item.input_audio_transcription.delta":
            if let delta = event["delta"] as? String {
                liveUserTranscript += delta
            }

        case "conversation.item.input_audio_transcription.completed":
            let text = (event["transcript"] as? String) ?? liveUserTranscript
            appendTranscript(.user, text: text)
            liveUserTranscript = ""

        case "response.output_audio_transcript.delta":
            if let delta = event["delta"] as? String {
                liveAssistantTranscript += delta
            }

        case "response.output_audio_transcript.done":
            let text = (event["transcript"] as? String) ?? liveAssistantTranscript
            appendTranscript(.assistant, text: text)
            liveAssistantTranscript = ""

        case "response.output_audio.delta":
            state = .speaking

        case "response.created":
            state = .thinking

        case "response.done":
            let calls = ConversationalVoiceSessionBuilder.functionCalls(from: event)
            if calls.isEmpty {
                state = .listening
            } else {
                runToolCalls(calls, index: 0)
            }

        default:
            break
        }
    }

    private func runToolCalls(_ calls: [RealtimeFunctionCall], index: Int) {
        guard index < calls.count else {
            state = .thinking
            client.requestResponse()
            return
        }
        let call = calls[index]
        state = .working(toolStatus(for: call.name))
        execute(call) { [weak self] output in
            guard let self else { return }
            self.client.sendFunctionOutput(
                callID: call.callID,
                output: ConversationalVoiceSessionBuilder.functionOutput(output)
            )
            self.runToolCalls(calls, index: index + 1)
        }
    }

    private func execute(_ call: RealtimeFunctionCall, completion: @escaping ToolCompletion) {
        switch call.name {
        case "perform_local_action":
            guard let request = call.arguments["request"] as? String else {
                completion(Self.invalidToolArguments())
                return
            }
            guard let onLocalAction else {
                completion(Self.unavailableTool())
                return
            }
            onLocalAction(request, completion)

        case "start_codex_task":
            guard let prompt = call.arguments["prompt"] as? String else {
                completion(Self.invalidToolArguments())
                return
            }
            guard let onStartCodexTask else {
                completion(Self.unavailableTool())
                return
            }
            onStartCodexTask(prompt, call.arguments["project"] as? String, completion)

        case "continue_codex_task":
            guard let instruction = call.arguments["instruction"] as? String else {
                completion(Self.invalidToolArguments())
                return
            }
            guard let onContinueCodexTask else {
                completion(Self.unavailableTool())
                return
            }
            onContinueCodexTask(instruction, completion)

        default:
            completion([
                "ok": false,
                "message": "That voice tool is not available.",
            ])
        }
    }

    private func appendTranscript(_ speaker: VoiceTranscriptSpeaker, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        transcript.append(VoiceTranscriptEntry(speaker: speaker, text: trimmed))
        if transcript.count > 40 {
            transcript.removeFirst(transcript.count - 40)
        }
    }

    private func handleDisconnect(_ message: String) {
        guard state != .idle else { return }
        client.disconnect()
        state = .failed(message)
    }

    private func toolStatus(for name: String) -> String {
        switch name {
        case "perform_local_action": return "Opening it…"
        case "start_codex_task": return "Handing that to Codex…"
        case "continue_codex_task": return "Updating the Codex task…"
        default: return "Working…"
        }
    }

    private static func invalidToolArguments() -> [String: Any] {
        ["ok": false, "message": "The request was missing required details."]
    }

    private static func unavailableTool() -> [String: Any] {
        ["ok": false, "message": "That tool is unavailable right now."]
    }
}
