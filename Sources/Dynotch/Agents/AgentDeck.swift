import Foundation

/// A Claude Code session the hooks have told Dynotch about.
struct AgentSession: Identifiable, Equatable {
    let id: String
    var project: String
}

/// A tool call waiting for an answer.
struct AgentApproval: Identifiable, Equatable {
    let id: UUID
    var sessionID: String
    var project: String
    var tool: String
    var command: String
}

/// Every Claude Code session in the notch: what's working, what's waiting and what's done.
@MainActor
final class AgentDeck: ObservableObject {
    static let shared = AgentDeck()

    @Published private(set) var sessions: [AgentSession] = []
    /// Tool calls waiting for an answer, oldest first.
    @Published private(set) var approvals: [AgentApproval] = []

    var hasSessions: Bool { !sessions.isEmpty }

    private init() {}

    func start() {}

    /// Back to nothing, between snapshot scenes.
    func clearSample() {
        sessions = []
        approvals = []
    }
}
