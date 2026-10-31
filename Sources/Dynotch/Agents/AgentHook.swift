import Foundation

/// `dynotch hook`: what Claude Code's hooks run.
enum AgentHook {
    /// The hook events Dynotch listens for, as the setup card writes them to `settings.json`, which
    /// merges them beside whatever is there. Only a permission request waits for an answer.
    static let events: [(name: String, waits: Bool)] = [
        ("SessionStart", false), ("SessionEnd", false), ("UserPromptSubmit", false), ("PreToolUse", false),
        ("PostToolUse", false), ("Notification", false), ("Stop", false), ("PermissionRequest", true),
    ]

    static func run(_ arguments: [String], _ socket: SocketClient, _ io: CommandLineClient.IO) -> Int32 { 0 }
}
