import Darwin
import DynotchShared
import Foundation

/// `dynotch hook`: what Claude Code's hooks run. It passes on what the notch needs and leaves the
/// rest behind. It only ever speaks up with a decision, and it never stops Claude Code: with no
/// answer, or no Dynotch, Claude Code's own prompt stays in charge.
extension AgentHook {
    /// All that goes to the notch beside the tool's input. Anything else in a hook's JSON stays here:
    /// the prompt, Claude's reply, what the tool printed and where the transcript is.
    private static let fields = ["hook_event_name", "session_id", "cwd", "tool_name", "notification_type", "message",
                                 "reason", "source", "agent_id", "tool_use_id"]

    /// SessionEnd hooks share 1.5 seconds, so nothing here waits as long as that.
    private static let patience: TimeInterval = 1

    static func run(_ arguments: [String], _ socket: SocketClient, _ io: CommandLineClient.IO) -> Int32 {
        guard let payload = (try? JSONSerialization.jsonObject(with: io.input())) as? [String: Any] else { return 0 }
        let request = request(from: payload, environment: io.environment, terminal: controllingTerminal())
        if isPermissionRequest(payload) {
            // As long as it takes: the deck answers, retires it, or the process is stopped.
            let answer = try? socket.send(request, timeout: nil)
            if let output = output(for: answer?["decision"]) { io.output(output) }
        } else {
            _ = try? socket.send(request, timeout: patience)
        }
        return 0
    }

    /// The terminal this session runs in, if any. zsh keeps `$TTY` to itself, so a hook has to ask.
    private static func controllingTerminal() -> String? {
        let terminal = open("/dev/tty", O_RDONLY | O_NOCTTY | O_CLOEXEC)
        guard terminal >= 0 else { return nil }
        defer { close(terminal) }
        return ttyname(terminal).map { String(cString: $0) }
    }

    /// What goes over the socket for a hook's JSON. `terminal` stands in for a `$TTY` it didn't get.
    static func request(from payload: [String: Any], environment: [String: String], terminal: String? = nil) -> [String: Any] {
        var request: [String: Any] = ["op": "hook"]
        for name in fields { request[name] = payload[name] as? String }
        if let input = payload["tool_input"] as? [String: Any] {
            let kept: [String: Any] = isPermissionRequest(payload) ? shown(input, tool: payload["tool_name"] as? String) : target(of: input)
            if !kept.isEmpty { request["tool_input"] = kept }
        }
        var origin = TerminalOrigin(environment: environment, folder: payload["cwd"] as? String)
        if origin.tty == nil { origin.tty = terminal }
        request["origin"] = origin.fields
        return request
    }

    /// What the approval shows: all of it, except a Bash call's description, which is Claude's own
    /// summary of the command and not what would run.
    private static func shown(_ input: [String: Any], tool: String?) -> [String: Any] {
        guard tool == "Bash" else { return input }
        return input.filter { $0.key != "description" }
    }

    private static func isPermissionRequest(_ payload: [String: Any]) -> Bool {
        payload["hook_event_name"] as? String == "PermissionRequest"
    }

    /// What Claude Code reads for a decision, and nil for anything that isn't one.
    static func output(for decision: Any?) -> String? {
        let behavior: [String: String]
        switch decision as? String {
        case "allow": behavior = ["behavior": "allow"]
        case "deny": behavior = ["behavior": "deny", "message": "Denied in Dynotch"]
        default: return nil
        }
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": behavior]]
        guard let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
