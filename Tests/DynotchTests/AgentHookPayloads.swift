import Foundation

/// What Claude Code's hooks send, from samples taken on a real run, with made-up values. Each holds
/// words that must never get past `dynotch hook`, so a test can look for them.
enum HookPayloads {
    static let session = "7f0c2f3a-41d7-4c1e-9a55-0d8d1b5e2c11"
    static let project = "/Users/sample/Desktop/FunProjects/lantern"
    static let transcript = "/Users/sample/.claude/projects/-Users-sample-lantern/7f0c2f3a.jsonl"

    private static func common(_ event: String) -> String {
        """
        "session_id": "\(session)", "transcript_path": "\(transcript)", "cwd": "\(project)",
        "scratchpad_dir": "/tmp/sample-scratch", "prompt_id": "c5fef749-d680-42a8-970d-3899a4321468",
        "permission_mode": "default", "effort": { "level": "medium" }, "hook_event_name": "\(event)"
        """
    }

    static let texts: [String: String] = [
        "SessionStart": """
        { \(common("SessionStart")), "source": "startup", "model": "claude-sample-1" }
        """,
        "SessionEnd": """
        { \(common("SessionEnd")), "reason": "prompt_input_exit" }
        """,
        "UserPromptSubmit": """
        { \(common("UserPromptSubmit")), "prompt": "SECRET-PROMPT please tidy the release notes" }
        """,
        "PreToolUse": """
        { \(common("PreToolUse")), "tool_name": "Bash",
          "tool_input": { "command": "swift build --product Lantern", "description": "SECRET-DESCRIPTION Build it" },
          "tool_use_id": "toolu_01Sample" }
        """,
        "PostToolUse": """
        { \(common("PostToolUse")), "tool_name": "Bash",
          "tool_input": { "command": "swift build --product Lantern", "description": "SECRET-DESCRIPTION Build it" },
          "tool_response": { "stdout": "SECRET-OUTPUT", "stderr": "", "interrupted": false },
          "tool_use_id": "toolu_01Sample", "duration_ms": 934 }
        """,
        "PermissionRequest": """
        { \(common("PermissionRequest")), "tool_name": "Bash",
          "tool_input": { "command": "swift build --product Lantern", "description": "SECRET-DESCRIPTION Build it" },
          "permission_suggestions": [{ "type": "setMode", "mode": "acceptEdits", "destination": "session" }] }
        """,
        "Notification": """
        { \(common("Notification")), "message": "Claude needs your permission", "notification_type": "permission_prompt" }
        """,
        "Stop": """
        { \(common("Stop")), "stop_hook_active": false, "last_assistant_message": "SECRET-REPLY All done.",
          "background_tasks": [], "session_crons": [] }
        """,
    ]

    /// A hook's JSON, with `changes` on top.
    static func payload(_ event: String, _ changes: [String: Any] = [:]) -> [String: Any] {
        let data = Data((texts[event] ?? "{}").utf8)
        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return payload.merging(changes) { $1 }
    }

    static func data(_ event: String, _ changes: [String: Any] = [:]) -> Data {
        (try? JSONSerialization.data(withJSONObject: payload(event, changes))) ?? Data()
    }
}
