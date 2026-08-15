import AVFoundation
import Foundation
import Speech

enum CommandVoiceState: Equatable {
    case idle
    case requestingPermission
    case listening
    case unavailable(String)
}

@MainActor
final class CommandVoiceInput: ObservableObject {
    @Published private(set) var state: CommandVoiceState = .idle {
        didSet { onStateChange?(state) }
    }
    @Published private(set) var transcript = ""

    var onStateChange: ((CommandVoiceState) -> Void)?
    var onTranscript: ((String) -> Void)?
    var onSubmit: ((String) -> Void)?

    private let audioEngine = AVAudioEngine()
    private let recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var sessionID: UUID?
    private var hasInstalledTap = false
    private var autoSubmitWorkItem: DispatchWorkItem?
    private let autoSubmitDelay: TimeInterval = 1.0

    init(locale: Locale = .current) {
        recognizer = SFSpeechRecognizer(locale: locale)
    }

    var isListening: Bool { state == .listening }

    func start() {
        guard state != .listening, state != .requestingPermission else { return }
        requestPermissionAndStart()
    }

    func toggle() {
        if isListening {
            stopAndSubmit()
        } else {
            start()
        }
    }

    func cancel() {
        finishSession(submit: false)
        state = .idle
    }

    private func requestPermissionAndStart() {
        guard state != .requestingPermission else { return }
        state = .requestingPermission

        Task {
            let speechStatus = await Self.requestSpeechAuthorization()
            guard speechStatus == .authorized else {
                state = .unavailable(Self.speechAuthorizationMessage(speechStatus))
                return
            }

            let microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard microphoneAllowed else {
                state = .unavailable(
                    "Microphone access is off. Enable it in System Settings → Privacy & Security → Microphone."
                )
                return
            }

            startSession()
        }
    }

    private func startSession() {
        finishSession(submit: false)
        guard let recognizer, recognizer.isAvailable else {
            state = .unavailable("Speech recognition is currently unavailable.")
            return
        }

        let sessionID = UUID()
        self.sessionID = sessionID
        transcript = ""

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .search
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }
        request.contextualStrings = [
            "Droppy", "in Droppy", "Silverdeck", "Emberdeck", "Mission Control",
            "Codex", "Ask Codex", "in Codex", "Notion", "Notion Calendar",
            "Bitwise", "APUSH", "Xcode", "open Droppy", "review in Droppy",
        ]
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.sampleRate > 0 else {
            state = .unavailable("Silverdeck could not access the microphone input.")
            finishSession(submit: false)
            return
        }

        inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: recordingFormat
        ) { buffer, _ in
            request.append(buffer)
        }
        hasInstalledTap = true

        recognitionTask = recognizer.recognitionTask(with: request) {
            [weak self] result, error in
            Task { @MainActor in
                guard let self, self.sessionID == sessionID else { return }
                if let result {
                    let value = CommandVoiceTranscriptNormalizer.normalize(
                        result.bestTranscription.formattedString
                    )
                    self.transcript = value
                    self.onTranscript?(value)
                    if result.isFinal {
                        self.finishSession(submit: true)
                    } else {
                        self.scheduleAutoSubmit(
                            for: sessionID,
                            transcript: value
                        )
                    }
                } else if let error {
                    self.finishSession(submit: false)
                    self.state = .unavailable(error.localizedDescription)
                }
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            state = .listening
        } catch {
            finishSession(submit: false)
            state = .unavailable(error.localizedDescription)
        }
    }

    private func stopAndSubmit() {
        finishSession(submit: true)
    }

    private func scheduleAutoSubmit(
        for sessionID: UUID,
        transcript: String
    ) {
        autoSubmitWorkItem?.cancel()
        autoSubmitWorkItem = nil
        guard CommandVoiceTranscriptNormalizer.isRunnable(transcript) else { return }

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard
                    let self,
                    self.sessionID == sessionID,
                    self.state == .listening
                else { return }
                self.finishSession(submit: true)
            }
        }
        autoSubmitWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + autoSubmitDelay,
            execute: workItem
        )
    }

    private func finishSession(submit: Bool) {
        let finalTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        sessionID = nil
        autoSubmitWorkItem?.cancel()
        autoSubmitWorkItem = nil

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if hasInstalledTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledTap = false
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil

        if case .unavailable = state {
            // Keep the permission or runtime message visible.
        } else {
            state = .idle
        }

        if submit, !finalTranscript.isEmpty {
            onSubmit?(finalTranscript)
        }
    }

    private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        if SFSpeechRecognizer.authorizationStatus() != .notDetermined {
            return SFSpeechRecognizer.authorizationStatus()
        }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private static func speechAuthorizationMessage(
        _ status: SFSpeechRecognizerAuthorizationStatus
    ) -> String {
        switch status {
        case .denied, .restricted:
            return "Speech recognition access is off. Enable it in System Settings → Privacy & Security → Speech Recognition."
        case .notDetermined:
            return "Speech recognition permission was not granted."
        case .authorized:
            return ""
        @unknown default:
            return "Speech recognition is unavailable."
        }
    }
}
