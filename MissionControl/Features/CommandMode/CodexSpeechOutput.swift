import AVFoundation
import Foundation

@MainActor
final class CodexSpeechOutput: NSObject, AVSpeechSynthesizerDelegate {
    var onSpeakingChanged: ((Bool) -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private var pendingText = ""
    private var queuedUtterances = 0
    private var speaking = false

    var isSpeaking: Bool { speaking }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func append(_ delta: String) {
        guard !delta.isEmpty else { return }
        pendingText += delta
        let split = Self.readyChunks(from: pendingText, flush: false)
        pendingText = split.remainder
        split.chunks.forEach(enqueue)
    }

    func finish() {
        let split = Self.readyChunks(from: pendingText, flush: true)
        pendingText = split.remainder
        split.chunks.forEach(enqueue)
        publishSpeakingState()
    }

    func stop() {
        pendingText = ""
        queuedUtterances = 0
        synthesizer.stopSpeaking(at: .immediate)
        setSpeaking(false)
    }

    private func enqueue(_ rawText: String) {
        let text = Self.spokenText(from: rawText)
        guard !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.49
        utterance.pitchMultiplier = 0.98
        utterance.preUtteranceDelay = queuedUtterances == 0 ? 0.03 : 0
        utterance.postUtteranceDelay = 0.02
        if let voice = AVSpeechSynthesisVoice(language: Locale.current.language.languageCode?.identifier ?? "en-US") {
            utterance.voice = voice
        }
        queuedUtterances += 1
        synthesizer.speak(utterance)
        setSpeaking(true)
    }

    private func publishSpeakingState() {
        if queuedUtterances == 0, !synthesizer.isSpeaking {
            setSpeaking(false)
        }
    }

    private func setSpeaking(_ value: Bool) {
        guard speaking != value else { return }
        speaking = value
        onSpeakingChanged?(value)
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in self?.setSpeaking(true) }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.queuedUtterances = max(0, self.queuedUtterances - 1)
            self.publishSpeakingState()
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.queuedUtterances = max(0, self.queuedUtterances - 1)
            self.publishSpeakingState()
        }
    }

    nonisolated static func readyChunks(
        from text: String,
        flush: Bool
    ) -> (chunks: [String], remainder: String) {
        var remainder = text
        var chunks: [String] = []

        while let boundary = speechBoundary(in: remainder) {
            let chunk = String(remainder[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
            remainder = String(remainder[boundary...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty { chunks.append(chunk) }
        }

        if flush {
            let tail = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { chunks.append(tail) }
            remainder = ""
        }
        return (chunks, remainder)
    }

    nonisolated static func spokenText(from rawText: String) -> String {
        var text = rawText
        text = text.replacingOccurrences(
            of: "\\[([^\\]]+)\\]\\([^)]+\\)",
            with: "$1",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "[`*_#>]",
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func speechBoundary(in text: String) -> String.Index? {
        guard text.count >= 36 else { return nil }
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            let length = text.distance(from: text.startIndex, to: next)
            if length >= 36,
               (character == "." || character == "!" || character == "?" || character == "\n")
            {
                return next
            }
            if length >= 180, character.isWhitespace {
                return next
            }
            index = next
        }
        return nil
    }
}
