/// What Claude Code's hooks mean to both ends: the card that installs them and the deck, in the app,
/// and `dynotch hook`, in the command, which is where the rest of this is.
package enum AgentHook {
    /// The hook events Dynotch listens for, as the setup card writes them to `settings.json`, which
    /// merges them beside whatever is there. Only a permission request waits for an answer.
    package static let events: [(name: String, waits: Bool)] = [
        ("SessionStart", false), ("SessionEnd", false), ("UserPromptSubmit", false), ("PreToolUse", false),
        ("PostToolUse", false), ("PostToolUseFailure", false), ("Notification", false), ("Stop", false),
        ("PermissionRequest", true),
    ]

    /// What names a tool's target, the only part of its input that goes along unless it's asking
    /// for permission.
    private static let targetKeys = ["command", "file_path", "notebook_path", "path", "pattern", "query", "url"]

    /// What names a tool's target, which is how a finished call is matched to the approval it answers.
    package static func target(of input: [String: Any]) -> [String: String] {
        input.reduce(into: [:]) { target, entry in
            if targetKeys.contains(entry.key), let value = entry.value as? String { target[entry.key] = value }
        }
    }
}
