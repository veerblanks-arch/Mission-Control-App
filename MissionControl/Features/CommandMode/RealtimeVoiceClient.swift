import AVFoundation
import Foundation
import Security

enum RealtimeAPIKeyStoreError: LocalizedError {
    case keychain(OSStatus)
    case invalidKey

    var errorDescription: String? {
        switch self {
        case let .keychain(status):
            return "The OpenAI API key could not be accessed in Keychain (\(status))."
        case .invalidKey:
            return "Enter a valid OpenAI API key."
        }
    }
}

struct RealtimeAPIKeyStore {
    private let service = "com.ranveer.droppy.realtime"
    private let account = "openai-api-key-v1"

    func load() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard
            status == errSecSuccess,
            let data = result as? Data,
            let value = String(data: data, encoding: .utf8),
            !value.isEmpty
        else {
            throw RealtimeAPIKeyStoreError.keychain(status)
        }
        return value
    }

    func save(_ rawValue: String) throws {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("sk-"), value.count > 12 else {
            throw RealtimeAPIKeyStoreError.invalidKey
        }
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw RealtimeAPIKeyStoreError.keychain(updateStatus)
        }

        var insert = query
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        insert[kSecValueData as String] = data
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        guard insertStatus == errSecSuccess else {
            throw RealtimeAPIKeyStoreError.keychain(insertStatus)
        }
    }

    func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RealtimeAPIKeyStoreError.keychain(status)
        }
    }
}

final class RealtimeVoiceClient {
    var onEvent: (([String: Any]) -> Void)?
    var onDisconnect: ((String) -> Void)?

    private let captureEngine = AVAudioEngine()
    private let playbackEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let audioQueue = DispatchQueue(label: "com.ranveer.droppy.realtime-audio")
    private let socketQueue = DispatchQueue(label: "com.ranveer.droppy.realtime-socket")
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 24_000,
        channels: 1,
        interleaved: false
    )!

    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var sessionUpdate: [String: Any]?
    private var inputConverter: AVAudioConverter?
    private var hasInputTap = false
    private var generation = UUID()
    private var didConfigureSession = false
    private var currentOutputItemID: String?
    private var playbackStartedAt: Date?
    private var scheduledOutputMilliseconds = 0.0

    init() {
        playbackEngine.attach(player)
        playbackEngine.connect(
            player,
            to: playbackEngine.mainMixerNode,
            format: outputFormat
        )
        playbackEngine.prepare()
    }

    deinit {
        disconnect()
    }

    func connect(
        apiKey: String,
        sessionUpdate: [String: Any]
    ) {
        disconnect()
        generation = UUID()
        didConfigureSession = false
        self.sessionUpdate = sessionUpdate

        guard let url = URL(
            string: "wss://api.openai.com/v1/realtime?model=\(ConversationalVoiceSessionBuilder.model)"
        ) else {
            notifyDisconnect("The Realtime service URL is invalid.")
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let session = URLSession(configuration: .default)
        let socket = session.webSocketTask(with: request)
        self.session = session
        self.socket = socket
        let currentGeneration = generation
        socket.resume()
        receiveNext(generation: currentGeneration)
    }

    func disconnect() {
        generation = UUID()
        stopCapture()
        stopPlayback(sendTruncation: false)
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        sessionUpdate = nil
        didConfigureSession = false
    }

    func sendText(_ text: String) {
        send([
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [[
                    "type": "input_text",
                    "text": text,
                ]],
            ],
        ])
        requestResponse()
    }

    func sendFunctionOutput(callID: String, output: String) {
        send([
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": callID,
                "output": output,
            ],
        ])
    }

    func requestResponse(instructions: String? = nil) {
        var response: [String: Any] = ["output_modalities": ["audio"]]
        if let instructions, !instructions.isEmpty {
            response["instructions"] = instructions
        }
        send([
            "type": "response.create",
            "response": response,
        ])
    }

    func injectSystemUpdate(_ text: String, responseInstructions: String) {
        send([
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [[
                    "type": "input_text",
                    "text": "System update from Codex: \(text)",
                ]],
            ],
        ])
        requestResponse(instructions: responseInstructions)
    }

    private func receiveNext(generation: UUID) {
        socket?.receive { [weak self] result in
            guard let self, self.generation == generation else { return }
            switch result {
            case let .success(message):
                let data: Data
                switch message {
                case let .string(string): data = Data(string.utf8)
                case let .data(value): data = value
                @unknown default:
                    self.receiveNext(generation: generation)
                    return
                }
                if
                    let value = try? JSONSerialization.jsonObject(with: data),
                    let event = value as? [String: Any]
                {
                    self.handle(event)
                }
                self.receiveNext(generation: generation)
            case let .failure(error):
                self.stopCapture()
                self.stopPlayback(sendTruncation: false)
                self.notifyDisconnect(error.localizedDescription)
            }
        }
    }

    private func handle(_ event: [String: Any]) {
        let type = event["type"] as? String ?? ""
        if type == "session.created", !didConfigureSession, let sessionUpdate {
            didConfigureSession = true
            send(sessionUpdate)
        } else if type == "session.updated", !captureEngine.isRunning {
            do {
                try startCapture()
            } catch {
                notifyDisconnect(error.localizedDescription)
            }
        } else if type == "response.output_audio.delta" {
            if let itemID = event["item_id"] as? String {
                currentOutputItemID = itemID
            }
            if
                let delta = event["delta"] as? String,
                let data = Data(base64Encoded: delta)
            {
                play(data)
            }
        } else if type == "input_audio_buffer.speech_started" {
            stopPlayback(sendTruncation: true)
        } else if type == "error" {
            let error = event["error"] as? [String: Any]
            let message = error?["message"] as? String
                ?? event["message"] as? String
                ?? "The Realtime service returned an error."
            notifyDisconnect(message)
        }

        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(event)
        }
    }

    private func startCapture() throws {
        stopCapture()
        let input = captureEngine.inputNode
        let sourceFormat = input.outputFormat(forBus: 0)
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else {
            throw NSError(
                domain: "RealtimeVoiceClient",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The microphone input format is unavailable."]
            )
        }
        guard let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else {
            throw NSError(
                domain: "RealtimeVoiceClient",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The microphone audio format could not be converted."]
            )
        }
        inputConverter = converter
        input.installTap(onBus: 0, bufferSize: 1_024, format: sourceFormat) {
            [weak self] buffer, _ in
            self?.audioQueue.async { [weak self] in
                self?.convertAndSend(buffer)
            }
        }
        hasInputTap = true
        captureEngine.prepare()
        try captureEngine.start()
    }

    private func stopCapture() {
        if captureEngine.isRunning { captureEngine.stop() }
        if hasInputTap {
            captureEngine.inputNode.removeTap(onBus: 0)
            hasInputTap = false
        }
        inputConverter = nil
    }

    private func convertAndSend(_ input: AVAudioPCMBuffer) {
        guard let converter = inputConverter else { return }
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 1
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else { return }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if suppliedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outStatus.pointee = .haveData
            return input
        }
        guard
            conversionError == nil,
            status != .error,
            output.frameLength > 0,
            let samples = output.floatChannelData?[0]
        else { return }

        var pcm = Data(capacity: Int(output.frameLength) * MemoryLayout<Int16>.size)
        for index in 0..<Int(output.frameLength) {
            let clamped = max(-1, min(1, samples[index]))
            var sample = Int16(
                clamped < 0
                    ? clamped * Float(Int16.min.magnitude)
                    : clamped * Float(Int16.max)
            ).littleEndian
            withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
        }
        send([
            "type": "input_audio_buffer.append",
            "audio": pcm.base64EncodedString(),
        ])
    }

    private func play(_ data: Data) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            let frameCount = data.count / MemoryLayout<Int16>.size
            guard
                frameCount > 0,
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: self.outputFormat,
                    frameCapacity: AVAudioFrameCount(frameCount)
                ),
                let samples = buffer.floatChannelData?[0]
            else { return }
            buffer.frameLength = AVAudioFrameCount(frameCount)
            data.withUnsafeBytes { rawBuffer in
                let values = rawBuffer.bindMemory(to: Int16.self)
                for index in 0..<frameCount {
                    samples[index] = Float(Int16(littleEndian: values[index])) / 32_768
                }
            }
            if self.playbackStartedAt == nil {
                self.playbackStartedAt = Date()
                self.scheduledOutputMilliseconds = 0
            }
            self.scheduledOutputMilliseconds += Double(frameCount) / 24.0
            do {
                if !self.playbackEngine.isRunning {
                    try self.playbackEngine.start()
                }
                self.player.scheduleBuffer(buffer)
                if !self.player.isPlaying { self.player.play() }
            } catch {
                self.notifyDisconnect(error.localizedDescription)
            }
        }
    }

    private func stopPlayback(sendTruncation: Bool) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            let elapsed = self.playbackStartedAt.map {
                min(Date().timeIntervalSince($0) * 1_000, self.scheduledOutputMilliseconds)
            } ?? 0
            self.player.stop()
            if
                sendTruncation,
                let itemID = self.currentOutputItemID,
                elapsed > 0
            {
                self.send([
                    "type": "conversation.item.truncate",
                    "item_id": itemID,
                    "content_index": 0,
                    "audio_end_ms": Int(elapsed),
                ])
            }
            self.currentOutputItemID = nil
            self.playbackStartedAt = nil
            self.scheduledOutputMilliseconds = 0
        }
    }

    private func send(_ value: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(value) else { return }
        socketQueue.async { [weak self] in
            guard
                let self,
                let socket = self.socket,
                let data = try? JSONSerialization.data(withJSONObject: value),
                let string = String(data: data, encoding: .utf8)
            else { return }
            socket.send(.string(string)) { [weak self] error in
                if let error { self?.notifyDisconnect(error.localizedDescription) }
            }
        }
    }

    private func notifyDisconnect(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onDisconnect?(message)
        }
    }
}
