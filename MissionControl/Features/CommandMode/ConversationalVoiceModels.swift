import Foundation

enum ConversationalVoiceState: Equatable {
    case idle
    case requestingMicrophone
    case connecting
    case listening
    case thinking
    case speaking
    case working(String)
    case failed(String)

    var isSessionActive: Bool {
        switch self {
        case .requestingMicrophone, .connecting, .listening, .thinking, .speaking, .working:
            return true
        case .idle, .failed:
            return false
        }
    }
}

enum VoiceTranscriptSpeaker: String, Equatable {
    case user
    case assistant
    case system
}

struct VoiceTranscriptEntry: Identifiable, Equatable {
    let id: UUID
    let speaker: VoiceTranscriptSpeaker
    let text: String

    init(
        id: UUID = UUID(),
        speaker: VoiceTranscriptSpeaker,
        text: String
    ) {
        self.id = id
        self.speaker = speaker
        self.text = text
    }
}

enum CodexVoicePrompt {
    static func initial(_ userText: String) -> String {
        """
        You are speaking with the user through Silverdeck's voice interface. Respond naturally and concisely for spoken playback while keeping your normal Codex capabilities. Answer ordinary questions directly. When the user asks for work, use the available tools and follow the normal approval boundaries. Avoid markdown-heavy formatting, long preambles, and narration of routine internal steps. Never claim an action succeeded unless it actually did.

        User: \(userText)
        """
    }

    static func isStopRequest(_ text: String) -> Bool {
        let words = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return [
            "cancel", "cancel that", "never mind", "nevermind", "stop",
            "stop that", "stop please",
        ].contains(words)
    }

    static func isLikelyPlaybackEcho(_ candidate: String, assistantText: String) -> Bool {
        let candidateWords = normalizedWords(candidate)
        let assistantWords = normalizedWords(assistantText)
        guard !candidateWords.isEmpty, !assistantWords.isEmpty else { return false }

        let candidatePhrase = candidateWords.joined(separator: " ")
        let assistantPhrase = assistantWords.joined(separator: " ")
        if assistantPhrase.contains(candidatePhrase) { return true }

        let candidateSet = Set(candidateWords)
        let overlap = candidateSet.intersection(Set(assistantWords)).count
        return candidateWords.count >= 3
            && Double(overlap) / Double(candidateSet.count) >= 0.8
    }

    private static func normalizedWords(_ text: String) -> [String] {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
