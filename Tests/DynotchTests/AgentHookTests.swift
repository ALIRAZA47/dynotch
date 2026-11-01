import Darwin
import Foundation
import Testing
@testable import Dynotch
@testable import DynotchCommand
import DynotchShared

/// A terminal for one `dynotch hook`.
private final class HookTerminal {
    var output = ""
    var error = ""

    func io(input: Data, socket: String, environment: [String: String] = [:]) -> CommandLineClient.IO {
        var io = CommandLineClient.IO()
        io.input = { input }
        io.output = { [unowned self] in output += $0 }
        io.error = { [unowned self] in error += $0 }
        io.environment = environment.merging(["DYNOTCH_SOCKET": socket]) { $1 }
        return io
    }
}

private final class Requests: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [SocketRequest] = []
    var last: SocketRequest? { lock.withLock { all.last } }
    var count: Int { lock.withLock { all.count } }
    func add(_ request: SocketRequest) { lock.withLock { all.append(request) } }
}

private struct Scratch {
    let folder = NSTemporaryDirectory() + "dyn-" + UUID().uuidString.prefix(8)
    var path: String { folder + "/run/s.sock" }
}

struct AgentHookTests {
    private func request(_ event: String, _ changes: [String: Any] = [:], environment: [String: String] = [:]) -> [String: Any] {
        AgentHook.request(from: HookPayloads.payload(event, changes), environment: environment)
    }

    private func text(of request: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
    }

    /// Runs a hook against a server that gives `answer`, and says what it left on the terminal.
    private func run(_ event: String, answer: [String: Any] = ["ok": true]) throws -> (code: Int32, terminal: HookTerminal, request: SocketRequest?) {
        let scratch = Scratch()
        defer { try? FileManager.default.removeItem(atPath: scratch.folder) }
        let requests = Requests()
        nonisolated(unsafe) let answer = answer
        let server = LocalSocketServer(path: scratch.path) { request, connection in
            requests.add(request)
            connection.reply(answer)
        }
        try server.start()
        defer { server.stop() }
        let terminal = HookTerminal()
        let code = CommandLineClient.run(["hook"], io: terminal.io(input: HookPayloads.data(event), socket: scratch.path))
        return (code, terminal, requests.last)
    }

    // MARK: What it sends

    @Test(arguments: Array(HookPayloads.texts.keys))
    func whatTheNotchHasNoBusinessHoldingStaysBehind(event: String) throws {
        let sent = try text(of: request(event))
        #expect(!sent.contains("SECRET-PROMPT"))
        #expect(!sent.contains("SECRET-REPLY"))
        #expect(!sent.contains("SECRET-OUTPUT"))
        #expect(!sent.contains("SECRET-DESCRIPTION"))
        #expect(!sent.contains("transcript"))
        #expect(!sent.contains("scratchpad"))
        #expect(!sent.contains("permission_suggestions"))
        #expect(!sent.contains("permission_mode"))
        #expect(!sent.contains("prompt_id"))
        #expect(!sent.contains("effort"))
    }

    @Test(arguments: Array(HookPayloads.texts.keys))
    func onlyTheListedFieldsGo(event: String) {
        let allowed: Set = ["op", "origin", "hook_event_name", "session_id", "cwd", "tool_name", "tool_input", "notification_type",
                            "message", "reason", "source", "agent_id", "tool_use_id"]
        #expect(Set(request(event).keys).isSubset(of: allowed))
    }

    @Test func itGoesAsTheHookOp() {
        let sent = request("Stop")
        #expect(sent["op"] as? String == "hook")
        #expect(sent["hook_event_name"] as? String == "Stop")
        #expect(sent["session_id"] as? String == HookPayloads.session)
        #expect(sent["cwd"] as? String == HookPayloads.project)
    }

    @Test func whatTheDeckUsesGoesAlong() {
        #expect(request("Notification")["notification_type"] as? String == "permission_prompt")
        #expect(request("Notification")["message"] as? String == "Claude needs your permission")
        #expect(request("SessionEnd")["reason"] as? String == "prompt_input_exit")
        #expect(request("SessionStart")["source"] as? String == "startup")
        #expect(request("PreToolUse")["tool_use_id"] as? String == "toolu_01Sample")
        #expect(request("PermissionRequest", ["agent_id": "agent-1"])["agent_id"] as? String == "agent-1")
    }

    @Test func itSaysWhereItCameFrom() throws {
        let sent = request("Stop", environment: ["TERM_PROGRAM": "ghostty", "TTY": "/dev/ttys004"])
        let origin = TerminalOrigin(fields: try #require(sent["origin"] as? [String: String]))
        #expect(origin.program == "ghostty")
        #expect(origin.tty == "/dev/ttys004")
        #expect(origin.folder == HookPayloads.project)
    }

    @Test func aPermissionRequestSendsTheCommandAndNotItsDescription() {
        let input = request("PermissionRequest")["tool_input"] as? [String: Any]
        #expect(input?["command"] as? String == "swift build --product Lantern")
        #expect(input?["description"] == nil)
    }

    @Test func aPermissionRequestKeepsWhatItWouldWrite() {
        let input = request("PermissionRequest", ["tool_name": "Write", "tool_input": ["file_path": "/a.txt", "content": "hello"]])["tool_input"]
        #expect((input as? [String: String]) == ["file_path": "/a.txt", "content": "hello"])
    }

    @Test func aPermissionRequestKeepsAllOfAnythingElse() {
        let sent = ["description": "Keep this", "url": "https://example.com", "prompt": "What it says"]
        let input = request("PermissionRequest", ["tool_name": "WebFetch", "tool_input": sent])["tool_input"]
        #expect((input as? [String: String]) == sent)
    }

    @Test func anythingElseKeepsOnlyWhatNamesTheTarget() {
        let bash = request("PreToolUse")["tool_input"] as? [String: String]
        #expect(bash == ["command": "swift build --product Lantern"])
        let write = request("PreToolUse", ["tool_name": "Write", "tool_input": ["file_path": "/a.txt", "content": "SECRET-CONTENT"]])
        #expect((write["tool_input"] as? [String: String]) == ["file_path": "/a.txt"])
        let edit = request("PostToolUse", ["tool_name": "Edit", "tool_input": ["file_path": "/a.txt", "old_string": "x", "new_string": "y"]])
        #expect((edit["tool_input"] as? [String: String]) == ["file_path": "/a.txt"])
        let fetch = request("PreToolUse", ["tool_name": "WebFetch", "tool_input": ["url": "https://example.com", "prompt": "SECRET"]])
        #expect((fetch["tool_input"] as? [String: String]) == ["url": "https://example.com"])
    }

    @Test func aToolWithNothingThatNamesItsTargetSendsNoInput() {
        let sent = request("PreToolUse", ["tool_name": "mcp__x__y", "tool_input": ["body": "SECRET"]])
        #expect(sent["tool_input"] == nil)
    }

    @Test func anyOtherEventKeepsOnlyTheTargetToo() {
        #expect(request("Stop", ["tool_input": ["command": "ls"]])["tool_input"] != nil)
        #expect(request("Stop", ["tool_input": ["body": "x"]])["tool_input"] == nil)
    }

    @Test func aFieldOfTheWrongKindGoesNowhere() {
        #expect(request("Stop", ["cwd": 12])["cwd"] == nil)
    }

    @Test func onlyAPermissionRequestWaits() {
        #expect(AgentHook.events.filter(\.waits).map(\.name) == ["PermissionRequest"])
        #expect(Set(AgentHook.events.map(\.name)) == Set(HookPayloads.texts.keys))
    }

    // MARK: What it prints

    @Test func allowIsPrintedInClaudeCodesWords() throws {
        let output = try #require(AgentHook.output(for: "allow"))
        let parsed = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: [String: Any]]
        #expect(parsed?["hookSpecificOutput"]?["hookEventName"] as? String == "PermissionRequest")
        #expect((parsed?["hookSpecificOutput"]?["decision"] as? [String: String]) == ["behavior": "allow"])
    }

    @Test func denyIsPrintedInClaudeCodesWords() throws {
        let output = try #require(AgentHook.output(for: "deny"))
        let parsed = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: [String: Any]]
        let decision = parsed?["hookSpecificOutput"]?["decision"] as? [String: String]
        #expect(decision?["behavior"] == "deny")
        #expect(decision?["message"]?.isEmpty == false)
    }

    @Test(arguments: ["Allow", "ALLOW", "allow ", " allow", "yes", "", "deny\n", "true", "allowed"])
    func anythingElseIsntADecision(word: String) {
        #expect(AgentHook.output(for: word) == nil)
    }

    @Test func aDecisionOfTheWrongKindIsntOne() {
        #expect(AgentHook.output(for: nil) == nil)
        #expect(AgentHook.output(for: true) == nil)
        #expect(AgentHook.output(for: 1) == nil)
        #expect(AgentHook.output(for: ["allow"]) == nil)
    }

    @Test func aPermissionRequestPrintsTheDecision() throws {
        let (code, terminal, request) = try run("PermissionRequest", answer: ["ok": true, "decision": "deny"])
        #expect(code == 0)
        #expect(terminal.output == AgentHook.output(for: "deny"))
        #expect(request?.string("hook_event_name") == "PermissionRequest")
    }

    @Test(arguments: [["ok": true], ["ok": true, "decision": "maybe"], ["ok": false, "error": "No"], ["decision": 1]] as [[String: Any]])
    func noDecisionPrintsNothing(answer: [String: Any]) throws {
        let (code, terminal, _) = try run("PermissionRequest", answer: answer)
        #expect(code == 0)
        #expect(terminal.output.isEmpty)
        #expect(terminal.error.isEmpty)
    }

    @Test(arguments: ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop"])
    func anythingButAPermissionRequestPrintsNothingWhateverItHears(event: String) throws {
        let (code, terminal, request) = try run(event, answer: ["ok": true, "decision": "allow"])
        #expect(code == 0)
        #expect(terminal.output.isEmpty)
        #expect(request?.string("hook_event_name") == event)
    }

    @Test(arguments: Array(HookPayloads.texts.keys))
    func aDeadSocketPrintsNothingAndExitsZero(event: String) {
        let scratch = Scratch()
        let terminal = HookTerminal()
        let code = CommandLineClient.run(["hook"], io: terminal.io(input: HookPayloads.data(event), socket: scratch.path))
        #expect(code == 0)
        #expect(terminal.output.isEmpty)
        #expect(terminal.error.isEmpty)
    }

    @Test(arguments: ["", "not json", "[1, 2]", "null"])
    func whatIsntAHooksJSONIsLeftAlone(input: String) throws {
        let scratch = Scratch()
        defer { try? FileManager.default.removeItem(atPath: scratch.folder) }
        let requests = Requests()
        let server = LocalSocketServer(path: scratch.path) { request, connection in
            requests.add(request)
            connection.reply(["ok": true])
        }
        try server.start()
        defer { server.stop() }
        let terminal = HookTerminal()
        #expect(CommandLineClient.run(["hook"], io: terminal.io(input: Data(input.utf8), socket: scratch.path)) == 0)
        #expect(terminal.output.isEmpty)
        #expect(requests.count == 0)
    }

    @Test func aServerThatNeverAnswersDoesntHoldUpAnEvent() throws {
        let scratch = Scratch()
        defer { try? FileManager.default.removeItem(atPath: scratch.folder) }
        let server = LocalSocketServer(path: scratch.path) { _, _ in }
        try server.start()
        defer { server.stop() }
        let started = Date.now
        let terminal = HookTerminal()
        #expect(CommandLineClient.run(["hook"], io: terminal.io(input: HookPayloads.data("SessionEnd"), socket: scratch.path)) == 0)
        // SessionEnd hooks share 1.5 seconds.
        #expect(Date.now.timeIntervalSince(started) < 1.5)
        #expect(terminal.output.isEmpty)
    }

    @Test func aConnectionThatEndsWithNoAnswerPrintsNothing() throws {
        let scratch = Scratch()
        defer { try? FileManager.default.removeItem(atPath: scratch.folder) }
        let server = LocalSocketServer(path: scratch.path) { _, _ in }
        try server.start()
        // Stops the server a moment after the hook has settled in to wait.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { server.stop() }
        let terminal = HookTerminal()
        #expect(CommandLineClient.run(["hook"], io: terminal.io(input: HookPayloads.data("PermissionRequest"), socket: scratch.path)) == 0)
        #expect(terminal.output.isEmpty)
    }

    @Test func aHookFindsItsOwnTerminalWhenTheShellKeptItToItself() {
        let payload: [String: Any] = ["hook_event_name": "Stop", "session_id": "s", "cwd": "/work"]
        let asked = AgentHook.request(from: payload, environment: [:], terminal: "/dev/ttys004")
        #expect((asked["origin"] as? [String: String])?["tty"] == "/dev/ttys004")
        let told = AgentHook.request(from: payload, environment: ["TTY": "/dev/ttys009"], terminal: "/dev/ttys004")
        #expect((told["origin"] as? [String: String])?["tty"] == "/dev/ttys009")
    }
}
