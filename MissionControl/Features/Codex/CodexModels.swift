import Foundation

enum CodexAgentRole: String, CaseIterable, Codable, Identifiable {
    case planner
    case builderA
    case builderB
    case reviewer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .planner: return "Planner"
        case .builderA: return "Builder A"
        case .builderB: return "Builder B"
        case .reviewer: return "Reviewer"
        }
    }

    var symbolName: String {
        switch self {
        case .planner: return "map"
        case .builderA: return "hammer"
        case .builderB: return "wrench.and.screwdriver"
        case .reviewer: return "checkmark.seal"
        }
    }

    var petAssetName: String {
        switch self {
        case .planner: return "planner-owl"
        case .builderA: return "builder-a-beaver"
        case .builderB: return "builder-b-fox"
        case .reviewer: return "reviewer-cat"
        }
    }

}

enum CodexRuntimeStatus: Equatable {
    case unavailable
    case idle
    case running
    case waiting
    case failed

    var title: String {
        switch self {
        case .unavailable: return "Saved history"
        case .idle: return "Idle"
        case .running: return "Running"
        case .waiting: return "Needs attention"
        case .failed: return "Failed"
        }
    }

    var isRunning: Bool { self == .running }

    var isActive: Bool {
        self == .running || self == .waiting
    }
}

struct CodexThreadSummary: Identifiable, Equatable {
    let id: String
    let title: String
    let preview: String
    let cwd: String
    let status: CodexRuntimeStatus
    let model: String?
    let updatedAt: Date

    var projectName: String {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        if !name.isEmpty { return name }
        return cwd.isEmpty ? "No Project" : cwd
    }

    func replacing(model: String?) -> CodexThreadSummary {
        CodexThreadSummary(
            id: id,
            title: title,
            preview: preview,
            cwd: cwd,
            status: status,
            model: model,
            updatedAt: updatedAt
        )
    }

    func replacing(status: CodexRuntimeStatus) -> CodexThreadSummary {
        CodexThreadSummary(
            id: id,
            title: title,
            preview: preview,
            cwd: cwd,
            status: status,
            model: model,
            updatedAt: updatedAt
        )
    }
}

struct CodexProjectGroup: Identifiable, Equatable {
    enum Kind: Equatable {
        case recentProject
        case normalChats
    }

    let id: String
    let name: String
    let subtitle: String
    let kind: Kind
    let threads: [CodexThreadSummary]
}

struct CodexProjectOption: Identifiable, Equatable {
    let id: String
    let name: String
    let path: String
}

struct CodexChatMessage: Identifiable, Equatable {
    enum Sender: Equatable {
        case user
        case agent
    }

    let id: String
    let sender: Sender
    var text: String
}

struct CodexDraftAttachment: Identifiable, Equatable {
    let id = UUID()
    let url: URL

    var isImage: Bool {
        let extensions = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"]
        return extensions.contains(url.pathExtension.lowercased())
    }
}

enum CodexConnectionState: Equatable {
    case stopped
    case connecting
    case ready
    case failed(String)
}

enum CodexFeatureError: LocalizedError {
    case unavailable
    case malformedResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The Codex App Server is unavailable."
        case .malformedResponse:
            return "Codex returned an unexpected response."
        case let .server(message):
            return message
        }
    }
}
