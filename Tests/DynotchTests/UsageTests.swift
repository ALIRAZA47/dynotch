import Darwin
import Foundation
import SwiftUI
import Testing
@testable import Dynotch

/// A terminal that keeps what's written to it.
private final class Terminal {
    var output = ""
    var error = ""
    var input = Data()

    func io(socket: String) -> CommandLineClient.IO {
        var io = CommandLineClient.IO()
        io.input = { [unowned self] in input }
        io.output = { [unowned self] in output += $0 }
        io.error = { [unowned self] in error += $0 }
        io.environment = ["DYNOTCH_SOCKET": socket]
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

/// `rate_limits` for the payloads below. Reset times count from the real clock, as the status line reads it.
private func limits(five: (used: String, resetsIn: TimeInterval)? = nil, seven: (used: String, resetsIn: TimeInterval)? = nil,
                    spend: Bool = false) -> String {
    func window(_ name: String, _ numbers: (used: String, resetsIn: TimeInterval)?) -> String? {
        numbers.map { #""\#(name)": {"used_percentage": \#($0.used), "resets_at": \#(Int(Date.now.timeIntervalSince1970 + $0.resetsIn))}"# }
    }
    let spendLimit = #""spend_limit": {"used_percentage": 140, "resets_at": 1893455200, "used_usd": 700, "limit_usd": 500, "period": "monthly"}"#
    let windows = [window("five_hour", five), window("seven_day", seven), spend ? spendLimit : nil].compactMap { $0 }
    return "{" + windows.joined(separator: ", ") + "}"
}

/// A real status line payload with made-up numbers, as it comes once a session has had a response.
private func payload(rateLimits: String) -> String {
    #"""
    {
     "session_id": "485ae712-5f58-4d70-9b0e-dec6c4551171",
     "transcript_path": "/Users/sample/.claude/projects/sample/485ae712-5f58-4d70-9b0e-dec6c4551171.jsonl",
     "cwd": "/Users/sample/Desktop/sample",
     "scratchpad_dir": "/tmp/sample",
     "prompt_id": "c5fef749-d680-42a8-970d-3899a4321468",
     "effort": {"level": "medium"},
     "session_name": "Sample session",
     "model": {"id": "claude-haiku-5-5", "display_name": "Haiku 5.5"},
     "workspace": {"current_dir": "/Users/sample/Desktop/sample", "project_dir": "/Users/sample/Desktop/sample", "added_dirs": [],
                   "git_worktree": "sample"},
     "version": "2.1.312",
     "output_style": {"name": "default"},
     "cost": {"total_cost_usd": 0.00460412, "total_duration_ms": 9258, "total_api_duration_ms": 4013, "total_lines_added": 0,
              "total_lines_removed": 0},
     "context_window": {"total_input_tokens": 48261, "total_output_tokens": 184, "context_window_size": 1000000,
                        "current_usage": {"input_tokens": 2, "output_tokens": 184, "cache_creation_input_tokens": 19787,
                                          "cache_read_input_tokens": 28472},
                        "used_percentage": 5, "remaining_percentage": 95},
     "exceeds_200k_tokens": false,
     "prompt_cache": {"warm": true, "caching_observed": true, "ttl": "1h", "expires_at": 1793455837, "requests": 1, "misses": 0,
                      "hit_ratio": 0.5899587658772093, "last_miss_at": null, "last_miss_cause": null, "miss_causes": {}},
     "fast_mode": false,
     "thinking": {"enabled": true},
     "rate_limits": \#(rateLimits)
    }
    """#
}

/// The same before the first response: no `rate_limits`, and nulls where the usage goes.
private let beforeTheFirstResponse = #"""
{
 "session_id": "485ae712-5f58-4d70-9b0e-dec6c4551171",
 "transcript_path": "/Users/sample/.claude/projects/sample/485ae712-5f58-4d70-9b0e-dec6c4551171.jsonl",
 "cwd": "/Users/sample/Desktop/sample",
 "scratchpad_dir": "/tmp/sample",
 "effort": {"level": "medium"},
 "model": {"id": "claude-haiku-5-5", "display_name": "Haiku 5.5"},
 "workspace": {"current_dir": "/Users/sample/Desktop/sample", "project_dir": "/Users/sample/Desktop/sample", "added_dirs": [],
               "git_worktree": "sample"},
 "version": "2.1.312",
 "output_style": {"name": "default"},
 "cost": {"total_cost_usd": 0, "total_duration_ms": 489, "total_api_duration_ms": 0, "total_lines_added": 0, "total_lines_removed": 0},
 "context_window": {"total_input_tokens": 0, "total_output_tokens": 0, "context_window_size": 1000000, "current_usage": null,
                    "used_percentage": null, "remaining_percentage": null},
 "exceeds_200k_tokens": false,
 "fast_mode": false,
 "thinking": {"enabled": true}
}
"""#

struct UsageStatusLineTests {
    /// Runs the status line on `input` with a server that says yes and remembers what it was asked.
    private func run(_ input: String, arguments: [String] = []) throws -> (code: Int32, terminal: Terminal, requests: Requests) {
        let scratch = Scratch()
        defer { try? FileManager.default.removeItem(atPath: scratch.folder) }
        let requests = Requests()
        let server = LocalSocketServer(path: scratch.path) { request, connection in
            requests.add(request)
            connection.reply(["ok": true])
        }
        try server.start()
        defer { server.stop() }
        let terminal = Terminal()
        terminal.input = Data(input.utf8)
        let code = CommandLineClient.run(["statusline"] + arguments, io: terminal.io(socket: scratch.path))
        return (code, terminal, requests)
    }

    private let both = payload(rateLimits: limits(five: ("62", 3600), seven: ("9", 86400)))

    @Test func beforeTheFirstResponseItPrintsWhatItHas() throws {
        let (code, terminal, requests) = try run(beforeTheFirstResponse)
        #expect(code == 0)
        #expect(terminal.output == "Haiku 5.5\n")
        #expect(requests.count == 0)
    }

    @Test func bothWindowsMakeTheWholeLine() throws {
        let (code, terminal, requests) = try run(both)
        #expect(code == 0)
        #expect(terminal.output == "Haiku 5.5 · 62% of 5 h · 9% of 7 d\n")
        #expect(requests.last?.op == "usage")
    }

    @Test func oneWindowIsEnough() throws {
        let five = try run(payload(rateLimits: limits(five: ("62", 3600))))
        #expect(five.terminal.output == "Haiku 5.5 · 62% of 5 h\n")
        #expect((five.requests.last?.fields["fiveHour"] as? [String: Any])?["used"] as? Double == 62)
        #expect(five.requests.last?.fields["sevenDay"] == nil)
        let seven = try run(payload(rateLimits: limits(seven: ("9", 86400))))
        #expect(seven.terminal.output == "Haiku 5.5 · 9% of 7 d\n")
        #expect(seven.requests.last?.fields["fiveHour"] == nil)
    }

    @Test func noWindowsAtAllSendsNothing() throws {
        let (_, terminal, requests) = try run(payload(rateLimits: "{}"))
        #expect(terminal.output == "Haiku 5.5\n")
        #expect(requests.count == 0)
    }

    @Test func decimalsAreRoundedAsTheNotchRoundsThem() throws {
        let (_, terminal, _) = try run(payload(rateLimits: limits(five: ("62.4", 3600), seven: ("79.6", 86400))))
        #expect(terminal.output == "Haiku 5.5 · 62% of 5 h · 80% of 7 d\n")
    }

    @Test func aPercentOutOfRangeIsKeptInRange() throws {
        let (_, terminal, _) = try run(payload(rateLimits: limits(five: ("250", 3600), seven: ("-5", 86400))))
        #expect(terminal.output == "Haiku 5.5 · 100% of 5 h · 0% of 7 d\n")
    }

    @Test func aWindowPastItsResetSaysSo() throws {
        let (_, terminal, _) = try run(payload(rateLimits: limits(five: ("62", -60), seven: ("9", 86400))))
        #expect(terminal.output == "Haiku 5.5 · 5 h reset · 9% of 7 d\n")
    }

    @Test func aGatewaysSpendLimitIsIgnored() throws {
        let alone = try run(payload(rateLimits: limits(spend: true)))
        #expect(alone.terminal.output == "Haiku 5.5\n")
        #expect(alone.requests.count == 0)
        let beside = try run(payload(rateLimits: limits(five: ("62", 3600), spend: true)))
        #expect(beside.terminal.output == "Haiku 5.5 · 62% of 5 h\n")
        #expect(Set(beside.requests.last?.fields.keys.map { $0 } ?? []) == ["op", "fiveHour"])
    }

    @Test func onlyNumbersGoOverTheSocket() throws {
        let request = try #require(try run(both).requests.last)
        #expect(Set(request.fields.keys) == ["op", "fiveHour", "sevenDay"])
        let window = try #require(request.fields["fiveHour"] as? [String: Any])
        #expect(Set(window.keys) == ["used", "resetsAt"])
    }

    @Test(arguments: ["not json at all", "", "[1, 2]", "42", "null", #"{"rate_limits": 5}"#, #"{"model": "Opus"}"#, "{"])
    func anythingElseStillPrintsSomething(input: String) throws {
        let (code, terminal, requests) = try run(input)
        #expect(code == 0)
        #expect(terminal.output == UsageStatusLine.nothingRead + "\n")
        #expect(requests.count == 0)
    }

    @Test(arguments: [#""62""#, "true", "null", "[62]"])
    func aPercentThatCantBeReadIsLeftOut(value: String) throws {
        let (code, terminal, requests) = try run(payload(rateLimits: limits(five: (value, 3600), seven: ("9", 86400))))
        #expect(code == 0)
        #expect(terminal.output == "Haiku 5.5 · 9% of 7 d\n")
        #expect(requests.last?.fields["fiveHour"] == nil)
    }

    @Test func aNumberTooBigForAnythingCantCrashIt() throws {
        let (code, terminal, _) = try run(payload(rateLimits: limits(five: ("1e999", 3600), seven: ("9", 86400))))
        #expect(code == 0)
        #expect(!terminal.output.isEmpty)
    }

    @Test func aPercentWithNoResetIsPrintedButNotSent() throws {
        let (_, terminal, requests) = try run(#"{"rate_limits": {"five_hour": {"used_percentage": 62}}}"#)
        #expect(terminal.output == "62% of 5 h\n")
        #expect(requests.count == 0)
    }

    @Test func aResetThatMakesNoSenseStillLeavesThePercent() throws {
        let (_, terminal, _) = try run(#"{"rate_limits": {"five_hour": {"used_percentage": 62, "resets_at": 0}}}"#)
        #expect(terminal.output == "62% of 5 h\n")
    }

    @Test func noModelLeavesTheNumbers() throws {
        let input = #"{"rate_limits": \#(limits(five: ("62", 3600)))}"#
        #expect(try run(input).terminal.output == "62% of 5 h\n")
    }

    @Test func aModelNameIsOneLineOfPlainText() throws {
        let input = #"{"model": {"display_name": "  Opus\n\u001b[31m 5.5\t"}}"#
        #expect(try run(input).terminal.output == "Opus[31m 5.5\n")
    }

    @Test func withDynotchNotRunningItStillPrints() {
        let scratch = Scratch()
        let terminal = Terminal()
        terminal.input = Data(both.utf8)
        let code = CommandLineClient.run(["statusline"], io: terminal.io(socket: scratch.path))
        #expect(code == 0)
        #expect(terminal.output == "Haiku 5.5 · 62% of 5 h · 9% of 7 d\n")
        #expect(terminal.error.isEmpty)
    }

    @Test func aDynotchThatDoesntAnswerCantHoldItUp() throws {
        let scratch = Scratch()
        defer { try? FileManager.default.removeItem(atPath: scratch.folder) }
        let server = LocalSocketServer(path: scratch.path) { _, _ in }
        try server.start()
        defer { server.stop() }
        let terminal = Terminal()
        terminal.input = Data(both.utf8)
        let started = Date.now
        let code = CommandLineClient.run(["statusline"], io: terminal.io(socket: scratch.path))
        #expect(Date.now.timeIntervalSince(started) < 0.5)
        #expect(code == 0)
        #expect(terminal.output == "Haiku 5.5 · 62% of 5 h · 9% of 7 d\n")
    }

    @Test(arguments: [["--nope"], ["--then"], ["word"], ["--then", ""]])
    func wrongUseIsNoReasonToGoBlank(arguments: [String]) throws {
        let (code, terminal, _) = try run(both, arguments: arguments)
        #expect(code == 0)
        #expect(terminal.output == "Haiku 5.5 · 62% of 5 h · 9% of 7 d\n")
    }

    // MARK: --then

    @Test func thenGetsTheSameJSONAndItsOutputIsPrinted() throws {
        let (code, terminal, _) = try run(both, arguments: ["--then", "cat"])
        #expect(code == 0)
        #expect(terminal.output == both)
    }

    @Test func thenStillSendsTheNumbers() throws {
        let (_, terminal, requests) = try run(both, arguments: ["--then", "echo mine"])
        #expect(terminal.output == "mine\n")
        #expect(requests.last?.op == "usage")
    }

    @Test func thenKeepsItsLinesAndColorsAsTheyAre() throws {
        let (_, terminal, _) = try run(both, arguments: ["--then", #"printf '\033[32mone\033[0m\ntwo'"#])
        #expect(terminal.output == "\u{1B}[32mone\u{1B}[0m\ntwo")
    }

    @Test func thenRunsInTheShellWithTheEnvironment() throws {
        let (_, terminal, _) = try run(both, arguments: ["--then", #"printf %s "$DYNOTCH_SOCKET" | wc -c | tr -d ' ' | grep -q '[0-9]' && echo yes"#])
        #expect(terminal.output == "yes\n")
    }

    @Test func aFailingCommandsOutputIsStillItsOutput() throws {
        let (code, terminal, _) = try run(both, arguments: ["--then", "echo mine; exit 3"])
        #expect(code == 0)
        #expect(terminal.output == "mine\n")
    }

    @Test(arguments: ["exit 3", "true", "echo; echo", "no-such-command-here 2>/dev/null"])
    func aCommandThatPrintsNothingLeavesDynotchsLine(command: String) throws {
        let (code, terminal, _) = try run(both, arguments: ["--then", command])
        #expect(code == 0)
        #expect(terminal.output == "Haiku 5.5 · 62% of 5 h · 9% of 7 d\n")
    }

    @Test func aCommandThatNeverReadsCantHurtIt() throws {
        // Far past what a pipe holds. Without its guard, this ends the whole test run with SIGPIPE.
        let long = String(repeating: "x", count: 1 << 20)
        let (code, terminal, _) = try run(long, arguments: ["--then", "exec 0<&-; echo mine"])
        #expect(code == 0)
        #expect(terminal.output == "mine\n")
    }

    @Test func aCommandThatPrintsBeforeItReadsCantWedgeIt() throws {
        let long = String(repeating: "x", count: 1 << 20)
        let (_, terminal, _) = try run(long, arguments: ["--then", #"head -c 1048576 /dev/zero | tr '\0' y; cat > /dev/null"#])
        #expect(terminal.output.utf8.count == 1 << 20)
    }

    @Test func aCommandThatTakesTooLongIsGivenUpOn() {
        let started = Date.now
        let output = UsageStatusLine.output(of: "exec sleep 5", given: Data(), environment: [:], patience: 0.1)
        #expect(output == nil)
        #expect(Date.now.timeIntervalSince(started) < 2)
    }

    /// Far more blocked tasks than the pool has threads, as when many tests wait at once. Feeding and
    /// reading a command must not need one of those threads, or everything waits for everything else.
    @Test func aCommandDoesntNeedASpareThreadFromThePool() {
        let held = DispatchSemaphore(value: 0)
        let tasks = ProcessInfo.processInfo.activeProcessorCount * 2
        func hold() { held.wait() }
        for _ in 0..<tasks { Task.detached { hold() } }
        defer { for _ in 0..<tasks { held.signal() } }
        #expect(UsageStatusLine.output(of: "cat", given: Data("mine".utf8), environment: [:], patience: 3) == "mine")
    }

    @Test func aReadingCanBeOfAnyMoment() {
        let now = Date.now
        let reading = UsageStatusLine.Reading(Data(payload(rateLimits: limits(five: ("62", 3600))).utf8))
        #expect(reading.line(at: now) == "Haiku 5.5 · 62% of 5 h")
        #expect(reading.line(at: now.addingTimeInterval(3601)) == "Haiku 5.5 · 5 h reset")
    }

    // MARK: dynotch status

    @Test func statusForReadingHasALine() {
        let usage: [String: Any] = ["fiveHour": ["percent": 62, "resetsAt": 1, "hasReset": false],
                                    "sevenDay": ["percent": 9, "resetsAt": 2, "hasReset": false], "secondsOld": 180]
        let text = CommandLineClient.summary(of: ["version": "1.6", "usage": usage])
        #expect(text == "Dynotch 1.6\nClaude usage: 62% of 5 h · 9% of 7 d · updated 3m ago\n")
    }

    @Test func statusSaysWhatHasReset() {
        let usage: [String: Any] = ["fiveHour": ["percent": 62, "resetsAt": 1, "hasReset": true], "sevenDay": NSNull(), "secondsOld": 7200]
        #expect(UsageStatusLine.summary(of: usage) == "Claude usage: 5 h reset · updated 2h ago")
    }

    @Test func withNoNumbersStatusSaysNothingAboutThem() {
        let usage: [String: Any] = ["fiveHour": NSNull(), "sevenDay": NSNull(), "secondsOld": NSNull()]
        #expect(CommandLineClient.summary(of: ["version": "1.6", "usage": usage]) == "Dynotch 1.6\n")
    }
}

/// The real `scripts/dynotch` and the real binary, against a server in this test.
struct UsageScriptTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let binary = root.appendingPathComponent(".build/debug/Dynotch").path
    private static var hasBinary: Bool { FileManager.default.isExecutableFile(atPath: binary) }

    private func statusline(_ arguments: [String] = [], input: String, socket: String) throws -> (code: Int32, output: String) {
        let process = Process()
        process.executableURL = Self.root.appendingPathComponent("scripts/dynotch")
        process.arguments = ["statusline"] + arguments
        process.environment = ["DYNOTCH_BIN": Self.binary, "DYNOTCH_SOCKET": socket, "PATH": "/usr/bin:/bin"]
        let feed = Pipe(), output = Pipe()
        process.standardInput = feed
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        feed.fileHandleForWriting.write(Data(input.utf8))
        try feed.fileHandleForWriting.close()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    @Test(.enabled(if: hasBinary)) func theNumbersReachTheNotchThroughTheScript() throws {
        let scratch = Scratch()
        defer { try? FileManager.default.removeItem(atPath: scratch.folder) }
        let requests = Requests()
        let server = LocalSocketServer(path: scratch.path) { request, connection in
            requests.add(request)
            connection.reply(["ok": true])
        }
        try server.start()
        defer { server.stop() }
        let result = try statusline(input: payload(rateLimits: limits(five: ("62", 3600), seven: ("9.5", 86400))), socket: scratch.path)
        #expect(result.code == 0)
        #expect(result.output == "Haiku 5.5 · 62% of 5 h · 10% of 7 d\n")
        #expect(requests.last?.op == "usage")
        #expect((requests.last?.fields["sevenDay"] as? [String: Any])?["used"] as? Double == 9.5)
    }

    @Test(.enabled(if: hasBinary)) func withNothingListeningTheScriptStillPrints() throws {
        let result = try statusline(input: beforeTheFirstResponse, socket: Scratch().path)
        #expect(result.code == 0)
        #expect(result.output == "Haiku 5.5\n")
    }

    @Test(.enabled(if: hasBinary)) func theScriptRunsThenInTheClient() throws {
        let result = try statusline(["--then", "wc -c | tr -d ' '"], input: "12345", socket: Scratch().path)
        #expect(result.code == 0)
        #expect(result.output == "5\n")
    }

    @Test(.enabled(if: hasBinary)) func aClosedInputIsNoReasonToCrash() throws {
        // Run through the shell, since it's the one that can start a process with its input closed.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", #""$0" --cli statusline <&-"#, Self.binary]
        process.environment = ["DYNOTCH_SOCKET": Scratch().path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == UsageStatusLine.nothingRead + "\n")
    }
}

@MainActor
@Suite(.serialized)
struct UsageStoreTests {
    private let start = Date(timeIntervalSince1970: 1_793_440_000)
    private final class Posted {
        var notices: [(notice: LiveNotice, seconds: TimeInterval)] = []
    }

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private func store() -> (UsageStore, Posted) {
        SnapshotRenderer.useScratchDefaults()
        return reopened()
    }

    /// A store that starts from whatever was saved, as after a relaunch.
    private func reopened() -> (UsageStore, Posted) {
        let posted = Posted()
        return (UsageStore(post: { posted.notices.append(($0, $1)) }), posted)
    }

    private func request(five: (used: Any, resetsIn: TimeInterval)? = nil, seven: (used: Any, resetsIn: TimeInterval)? = nil) throws -> SocketRequest {
        var fields: [String: Any] = ["op": "usage"]
        func window(_ numbers: (used: Any, resetsIn: TimeInterval)) -> [String: Any] {
            ["used": numbers.used, "resetsAt": start.timeIntervalSince1970 + numbers.resetsIn]
        }
        fields["fiveHour"] = five.map(window)
        fields["sevenDay"] = seven.map(window)
        return try #require(SocketRequest(line: JSONSerialization.data(withJSONObject: fields)))
    }

    private func raw(_ line: String) throws -> SocketRequest { try #require(SocketRequest(line: Data(line.utf8))) }

    // MARK: Numbers

    @Test func itHoldsBothWindowsAndWhenTheyCame() throws {
        let (store, _) = store()
        #expect(store.numbers == nil)
        let answer = store.apply(try request(five: (62, 3600), seven: (9, 86400)), now: at(0))
        #expect(answer["ok"] as? Bool == true)
        #expect(store.numbers?.fiveHour == UsageWindow(percent: 62, resetsAt: at(3600)))
        #expect(store.numbers?.sevenDay == UsageWindow(percent: 9, resetsAt: at(86400)))
        #expect(store.numbers?.receivedAt == at(0))
    }

    @Test(arguments: [(-5.0, 0), (0.4, 0), (49.5, 50), (62.4, 62), (100.0, 100), (250.0, 100)])
    func aPercentStaysInRange(input: Double, expected: Int) throws {
        let (store, _) = store()
        _ = store.apply(try request(five: (input, 3600)), now: at(0))
        #expect(store.numbers?.fiveHour?.percent == expected)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func aPercentThatIsntANumberIsRefused(input: Double) {
        #expect(UsageWindow(used: input, resetsAt: 1_793_443_600, now: start) == nil)
        #expect(UsageWindow(used: 50, resetsAt: input, now: start) == nil)
    }

    @Test(arguments: [#"{"op":"usage","fiveHour":{"used":"62","resetsAt":1793443600}}"#,
                      #"{"op":"usage","fiveHour":{"used":true,"resetsAt":1793443600}}"#,
                      #"{"op":"usage","fiveHour":{"used":62}}"#,
                      #"{"op":"usage","fiveHour":{"resetsAt":1793443600}}"#,
                      #"{"op":"usage","fiveHour":{"used":1e999,"resetsAt":1793443600}}"#,
                      #"{"op":"usage","fiveHour":5}"#,
                      #"{"op":"usage"}"#])
    func nonsenseChangesNothing(line: String) throws {
        let (store, _) = store()
        // Refused outright when it can't be read as JSON at all, which is the socket's job.
        guard let request = SocketRequest(line: Data(line.utf8)) else { return }
        let answer = store.apply(request, now: at(0))
        #expect(answer["ok"] as? Bool == false)
        #expect(store.numbers == nil)
    }

    @Test(arguments: [-31.0 * 86400, 31.0 * 86400, -1_793_440_000, 1_793_440_000_000])
    func aResetAbsurdlyOldOrFarOffIsIgnored(resetsIn: TimeInterval) throws {
        let (store, _) = store()
        _ = store.apply(try request(five: (62, 3600)), now: at(0))
        _ = store.apply(try request(five: (70, resetsIn)), now: at(60))
        #expect(store.numbers?.fiveHour?.percent == 62)
        #expect(store.numbers?.receivedAt == at(0))
    }

    @Test func aResetThatHasOnlyJustPassedIsBelieved() throws {
        let (store, _) = store()
        _ = store.apply(try request(five: (62, -3600)), now: at(0))
        #expect(store.numbers?.fiveHour?.hasReset(at: at(0)) == true)
    }

    @Test func oneWindowCanComeAlone() throws {
        let (store, _) = store()
        _ = store.apply(try request(seven: (38, 86400)), now: at(0))
        #expect(store.numbers?.fiveHour == nil)
        #expect(store.numbers?.sevenDay?.percent == 38)
    }

    @Test func aWindowLeftOutStaysAsItWas() throws {
        let (store, _) = store()
        _ = store.apply(try request(five: (62, 3600), seven: (9, 86400)), now: at(0))
        // As Claude Code does once the five hours reset: the window just isn't there any more.
        _ = store.apply(try request(seven: (10, 86400)), now: at(3700))
        #expect(store.numbers?.fiveHour == UsageWindow(percent: 62, resetsAt: at(3600)))
        #expect(store.numbers?.sevenDay?.percent == 10)
    }

    @Test func aBadWindowDoesntCostTheGoodOne() throws {
        let (store, _) = store()
        let answer = store.apply(try request(five: ("sixty", 3600), seven: (9, 86400)), now: at(0))
        #expect(answer["ok"] as? Bool == true)
        #expect(store.numbers?.fiveHour == nil)
        #expect(store.numbers?.sevenDay?.percent == 9)
    }

    // MARK: Redrawing

    @Test func theSameNumbersAgainRedrawNothing() throws {
        let (store, _) = store()
        _ = store.apply(try request(five: (62, 3600), seven: (9, 86400)), now: at(0))
        var changes = 0
        let watching = store.objectWillChange.sink { changes += 1 }
        for seconds in stride(from: 1.0, to: UsageStore.ageStep, by: 5) {
            _ = store.apply(try request(five: (62, 3600), seven: (9, 86400)), now: at(seconds))
        }
        withExtendedLifetime(watching) { #expect(changes == 0) }
        #expect(store.numbers?.receivedAt == at(0))
    }

    @Test func aChangeTooSmallToSeeRedrawsNothing() throws {
        let (store, _) = store()
        _ = store.apply(try request(five: (62, 3600)), now: at(0))
        var changes = 0
        let watching = store.objectWillChange.sink { changes += 1 }
        _ = store.apply(try request(five: (62.3, 3600)), now: at(1))
        withExtendedLifetime(watching) { #expect(changes == 0) }
    }

    @Test func theAgeStillMovesNowAndThen() throws {
        let (store, _) = store()
        _ = store.apply(try request(five: (62, 3600)), now: at(0))
        var changes = 0
        let watching = store.objectWillChange.sink { changes += 1 }
        _ = store.apply(try request(five: (62, 3600)), now: at(UsageStore.ageStep))
        withExtendedLifetime(watching) { #expect(changes == 1) }
        #expect(store.numbers?.receivedAt == at(UsageStore.ageStep))
    }

    @Test func newNumbersRedrawAtOnce() throws {
        let (store, _) = store()
        _ = store.apply(try request(five: (62, 3600)), now: at(0))
        var changes = 0
        let watching = store.objectWillChange.sink { changes += 1 }
        _ = store.apply(try request(five: (63, 3600)), now: at(1))
        withExtendedLifetime(watching) { #expect(changes == 1) }
        #expect(store.numbers?.receivedAt == at(1))
    }

    // MARK: Saving

    @Test func theNumbersSurviveARelaunch() throws {
        let (store, _) = store()
        _ = store.apply(try request(five: (62, 3600), seven: (9, 86400)), now: at(0))
        let (next, _) = reopened()
        #expect(next.numbers == store.numbers)
        #expect(next.numbers?.fiveHour?.percent == 62)
    }

    @Test func onlyTheNumbersAreSaved() throws {
        let (store, _) = store()
        _ = store.apply(try request(five: (62, 3600), seven: (9, 86400)), now: at(0))
        let data = try #require(UserDefaults.dynotch.data(forKey: "usageNumbers"))
        let saved = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(saved.keys) == ["fiveHour", "sevenDay", "receivedAt"])
        #expect(Set((saved["fiveHour"] as? [String: Any])?.keys.map { $0 } ?? []) == ["percent", "resetsAt"])
    }

    @Test func somethingUnreadableSavedIsNoNumbers() {
        SnapshotRenderer.useScratchDefaults()
        UserDefaults.dynotch.set(Data("nonsense".utf8), forKey: "usageNumbers")
        #expect(reopened().0.numbers == nil)
    }

    @Test func samplesAreNeverSaved() {
        let (store, _) = store()
        store.loadSample(fiveHour: UsageWindow(percent: 62, resetsAt: at(3600)), sevenDay: nil, receivedAt: at(0))
        #expect(store.numbers?.fiveHour?.percent == 62)
        #expect(reopened().0.numbers == nil)
        store.clearSample()
        #expect(store.numbers == nil)
    }

    // MARK: Heads-up

    @Test func theHeadsUpComesAtEighty() throws {
        let (store, posted) = store()
        _ = store.apply(try request(five: (79, 3600)), now: at(0))
        #expect(posted.notices.isEmpty)
        _ = store.apply(try request(five: (80, 3600)), now: at(60))
        let (notice, seconds) = try #require(posted.notices.first)
        #expect(posted.notices.count == 1)
        #expect(seconds == UsageStore.warningSeconds)
        #expect(notice.key == "usage")
        #expect(notice.text == "Claude usage")
        #expect(notice.detail == "80% of your 5 hours")
        #expect(notice.tint == .orange)
        #expect(!notice.fromScript)
        #expect(notice.timing == .waits)
        #expect(notice.recall == .whole)
        #expect(notice.actions == [NoticeAction(title: "Show", kind: .showUsage)])
    }

    @Test func whatTheNotchRoundsToEightyCounts() throws {
        let (store, posted) = store()
        _ = store.apply(try request(five: (79.4, 3600)), now: at(0))
        #expect(posted.notices.isEmpty)
        _ = store.apply(try request(five: (79.6, 3600)), now: at(1))
        #expect(posted.notices.count == 1)
    }

    @Test func nearlyOutItsRed() throws {
        let (store, posted) = store()
        _ = store.apply(try request(five: (96, 3600)), now: at(0))
        #expect(posted.notices.first?.notice.tint == .red)
    }

    @Test func itComesOncePerReset() throws {
        let (store, posted) = store()
        _ = store.apply(try request(five: (80, 3600)), now: at(0))
        _ = store.apply(try request(five: (81, 3600)), now: at(60))
        _ = store.apply(try request(five: (95, 3600)), now: at(120))
        #expect(posted.notices.count == 1)
    }

    @Test func droppingAndReachingItAgainDoesntWarnTwice() throws {
        let (store, posted) = store()
        _ = store.apply(try request(five: (85, 3600)), now: at(0))
        _ = store.apply(try request(five: (40, 3600)), now: at(60))
        _ = store.apply(try request(five: (85, 3600)), now: at(120))
        #expect(posted.notices.count == 1)
    }

    @Test func aResetTimeThatMovesWithinThePeriodDoesntWarnTwice() throws {
        let (store, posted) = store()
        _ = store.apply(try request(five: (85, 3600)), now: at(0))
        // The five hours are a rolling window, so the time can shift while the period runs.
        _ = store.apply(try request(five: (86, 7200)), now: at(600))
        #expect(posted.notices.count == 1)
    }

    @Test func aNewPeriodWarnsAgain() throws {
        let (store, posted) = store()
        _ = store.apply(try request(five: (85, 3600)), now: at(0))
        _ = store.apply(try request(five: (20, 3600 + 5 * 3600)), now: at(3601))
        #expect(posted.notices.count == 1)
        _ = store.apply(try request(five: (82, 3600 + 5 * 3600)), now: at(7200))
        #expect(posted.notices.count == 2)
    }

    @Test func aRelaunchRemembersWhichResetItWarnedFor() throws {
        let (store, posted) = store()
        _ = store.apply(try request(five: (85, 3600)), now: at(0))
        #expect(posted.notices.count == 1)
        let (next, nextPosted) = reopened()
        _ = next.apply(try request(five: (86, 3600)), now: at(60))
        #expect(nextPosted.notices.isEmpty)
        _ = next.apply(try request(five: (86, 3600 + 5 * 3600)), now: at(3601))
        #expect(nextPosted.notices.count == 1)
    }

    @Test func eachWindowHasItsOwnReset() throws {
        let (store, posted) = store()
        _ = store.apply(try request(five: (85, 3600), seven: (10, 86400)), now: at(0))
        _ = store.apply(try request(five: (85, 3600), seven: (80, 86400)), now: at(60))
        #expect(posted.notices.map(\.notice.detail) == ["85% of your 5 hours", "80% of your 7 days"])
    }

    @Test func twoReachingItAtOnceAreOneNotice() throws {
        // Two with the same key would replace each other, and one would never be seen.
        let (store, posted) = store()
        _ = store.apply(try request(five: (96, 3600), seven: (82, 86400)), now: at(0))
        #expect(posted.notices.count == 1)
        #expect(posted.notices.first?.notice.detail == "96% of your 5 hours · 82% of your 7 days")
        #expect(posted.notices.first?.notice.tint == .red)
        _ = store.apply(try request(five: (97, 3600), seven: (83, 86400)), now: at(60))
        #expect(posted.notices.count == 1)
    }

    @Test func aWindowThatHasAlreadyResetSaysNothing() throws {
        let (store, posted) = store()
        _ = store.apply(try request(five: (95, -60)), now: at(0))
        #expect(posted.notices.isEmpty)
    }

    @Test func aWindowThatDidntArriveSaysNothing() throws {
        let (store, posted) = store()
        store.loadSample(fiveHour: UsageWindow(percent: 95, resetsAt: at(3600)), sevenDay: nil, receivedAt: at(0))
        _ = store.apply(try request(seven: (10, 86400)), now: at(60))
        #expect(posted.notices.isEmpty)
    }

    @Test func withTheSwitchOffTheNumbersGoOnQuietly() throws {
        let (store, posted) = store()
        AppSettings.shared.liveUsage = false
        defer { AppSettings.shared.liveUsage = true }
        _ = store.apply(try request(five: (90, 3600)), now: at(0))
        #expect(posted.notices.isEmpty)
        #expect(store.numbers?.fiveHour?.percent == 90)
    }

    @Test func turningTheSwitchBackOnWarnsAboutWhatWentUnsaid() throws {
        let (store, posted) = store()
        AppSettings.shared.liveUsage = false
        _ = store.apply(try request(five: (90, 3600)), now: at(0))
        AppSettings.shared.liveUsage = true
        _ = store.apply(try request(five: (90, 3600)), now: at(1))
        #expect(posted.notices.count == 1)
    }

    // MARK: Status and the socket

    @Test func statusReportsBothWindowsAndTheirAge() throws {
        let (store, _) = store()
        _ = store.apply(try request(five: (62, 3600), seven: (9, 86400)), now: at(0))
        let report = store.statusReport(at: at(180))
        let five = try #require(report["fiveHour"] as? [String: Any])
        #expect(five["percent"] as? Int == 62)
        #expect(five["resetsAt"] as? Int == Int(at(3600).timeIntervalSince1970))
        #expect(five["hasReset"] as? Bool == false)
        #expect(report["secondsOld"] as? Int == 180)
        #expect((store.statusReport(at: at(3601))["fiveHour"] as? [String: Any])?["hasReset"] as? Bool == true)
        #expect(JSONSerialization.isValidJSONObject(report))
    }

    @Test func statusWithNoNumbersIsStillJSON() {
        let (store, _) = store()
        let report = store.statusReport(at: at(0))
        #expect(report["fiveHour"] is NSNull)
        #expect(report["sevenDay"] is NSNull)
        #expect(report["secondsOld"] is NSNull)
        #expect(JSONSerialization.isValidJSONObject(report))
    }

    @Test func theOnlyOpIsUsage() {
        let router = SocketRouter()
        store().0.start(on: router)
        #expect(router.ops == ["usage"])
    }

    @Test func numbersArriveOverTheSocketAndShowInStatus() async throws {
        let (store, _) = store()
        let scratch = Scratch()
        defer { try? FileManager.default.removeItem(atPath: scratch.folder) }
        let router = SocketRouter()
        store.start(on: router)
        router.start(path: scratch.path)
        defer { router.stop() }
        let path = scratch.path
        let resets = Date.now.timeIntervalSince1970 + 3600
        let answer = try await Task.detached {
            try SocketClient(path: path).send(["op": "usage", "fiveHour": ["used": 62.4, "resetsAt": resets]], timeout: 2)
        }.value
        #expect(answer["ok"] as? Bool == true)
        #expect(store.numbers?.fiveHour?.percent == 62)
        let status = try await Task.detached { try SocketClient(path: path).send(["op": "status"], timeout: 2) }.value
        #expect(((status["usage"] as? [String: Any])?["fiveHour"] as? [String: Any])?["percent"] as? Int == 62)
    }
}

/// What the glance and the chip say, which is worked out apart from the views.
struct UsageNumbersTests {
    private let now = Date(timeIntervalSince1970: 1_793_440_000)

    private func numbers(five: (percent: Int, resetsIn: TimeInterval)? = nil, seven: (percent: Int, resetsIn: TimeInterval)? = nil,
                         age: TimeInterval = 180) -> UsageNumbers {
        func window(_ numbers: (percent: Int, resetsIn: TimeInterval)?) -> UsageWindow? {
            numbers.map { UsageWindow(percent: $0.percent, resetsAt: now.addingTimeInterval($0.resetsIn)) }
        }
        return UsageNumbers(fiveHour: window(five), sevenDay: window(seven), receivedAt: now.addingTimeInterval(-age))
    }

    @Test func itReadsLikeTheMockUp() {
        let numbers = numbers(five: (62, 74 * 60), seven: (38, 76 * 3600))
        #expect(numbers.main(at: now) == .fiveHour)
        #expect(numbers.title(at: now) == "62% of your 5 hours")
        #expect(numbers.subtitle(at: now) == "Resets in 1 h 14 min · 7 days 38%")
        #expect(numbers.age(at: now) == "Updated 3m ago")
    }

    @Test func theFullerSevenDaysTakeOver() {
        let numbers = numbers(five: (12, 3600), seven: (84, 76 * 3600))
        #expect(numbers.main(at: now) == .sevenDay)
        #expect(numbers.title(at: now) == "84% of your 7 days")
        #expect(numbers.subtitle(at: now) == "Resets in 3 days 4 h · 5 hours 12%")
    }

    @Test func levelGoesToTheFiveHours() {
        #expect(numbers(five: (40, 3600), seven: (40, 86400)).main(at: now) == .fiveHour)
    }

    @Test func aLimitThatHasResetGivesUpItsNumber() {
        let numbers = numbers(five: (90, -60), seven: (38, 76 * 3600))
        #expect(numbers.main(at: now) == .sevenDay)
        #expect(numbers.title(at: now) == "38% of your 7 days")
        #expect(numbers.subtitle(at: now) == "Resets in 3 days 4 h · 5 hours reset")
        #expect(!numbers.subtitle(at: now).contains("90"))
    }

    @Test func aSevenDaysThatHasResetSaysSoToo() {
        #expect(numbers(five: (62, 3600), seven: (84, -60)).subtitle(at: now) == "Resets in 1 h · 7 days reset")
    }

    @Test func itResetsTheMomentTheTimeComes() {
        let window = UsageWindow(percent: 62, resetsAt: now)
        #expect(!window.hasReset(at: now.addingTimeInterval(-1)))
        #expect(window.hasReset(at: now))
    }

    @Test func withEverythingResetThereIsNoNumber() {
        let numbers = numbers(five: (62, -60), seven: (38, -60))
        #expect(numbers.main(at: now) == nil)
        #expect(numbers.title(at: now) == "Your limits have reset")
        #expect(numbers.subtitle(at: now) == "New numbers come with your next message")
    }

    @Test func aLoneLimitIsNamed() {
        #expect(numbers(five: (62, -60)).title(at: now) == "Your 5 hours have reset")
        #expect(numbers(seven: (62, -60)).title(at: now) == "Your 7 days have reset")
    }

    @Test func aLoneLimitHasNothingBesideIt() {
        #expect(numbers(five: (62, 74 * 60)).subtitle(at: now) == "Resets in 1 h 14 min")
    }

    private static let ages: [(TimeInterval, String)] = [
        (0, "Updated just now"), (59, "Updated just now"), (60, "Updated 1m ago"), (3600, "Updated 1h ago"),
        (169_200, "Updated 47h ago"), (172_800, "Updated 2d ago"), (7_776_000, "Updated 90d ago"),
    ]

    @Test(arguments: ages)
    func theAgeIsAlwaysSaid(age: TimeInterval, text: String) {
        #expect(numbers(five: (62, 3600), age: age).age(at: now) == text)
    }

    private static let timesLeft: [(TimeInterval, String)] = [
        (30, "1 min"), (840, "14 min"), (4381, "1 h 14 min"), (3600, "1 h"), (7200, "2 h"),
        (86400, "1 day"), (100_800, "1 day 4 h"), (273_600, "3 days 4 h"), (604_800, "7 days"),
    ]

    @Test(arguments: timesLeft)
    func timeLeftReadsPlainly(seconds: TimeInterval, text: String) {
        #expect(Format.timeLeft(to: now.addingTimeInterval(seconds), from: now) == text)
    }

    @Test func aMomentPastTheResetIsNeverNothingLeft() {
        #expect(Format.timeLeft(to: now.addingTimeInterval(-5), from: now) == "1 min")
    }

    @Test func theRingWarmsUpTowardTheLimit() {
        let reset = Date.now
        #expect(UsageWindow(percent: 79, resetsAt: reset).tint(.blue) == .blue)
        #expect(UsageWindow(percent: 80, resetsAt: reset).tint(.blue) == .orange)
        #expect(UsageWindow(percent: 94, resetsAt: reset).tint(.blue) == .orange)
        #expect(UsageWindow(percent: 95, resetsAt: reset).tint(.blue) == .red)
    }

    @Test func theShortFormsReadAsTheyShould() {
        #expect(UsageLimit.fiveHour.short(percent: 62, hasReset: false) == "62% of 5 h")
        #expect(UsageLimit.sevenDay.short(percent: 9, hasReset: true) == "7 d reset")
    }
}

@MainActor
@Suite(.serialized)
struct UsageGlanceTests {
    private let geometry = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                                         closedSize: CGSize(width: 185, height: 32), hasHardwareNotch: true)

    /// A glance on the Today view, with whatever else is going on set aside.
    private func glancing(showingRecent: Bool = false) -> NotchViewModel {
        SnapshotRenderer.useScratchDefaults()
        let viewModel = NotchViewModel(geometry: geometry)
        viewModel.stage(phase: .glance, activity: .idle, showingRecent: showingRecent)
        return viewModel
    }

    @Test func theChipTurnsTheGlance() {
        let viewModel = glancing()
        defer { viewModel.stage(phase: .closed, activity: .idle) }
        viewModel.showUsage()
        #expect(viewModel.glanceContent == .usage)
    }

    @Test func aButtonInTheRecentListTurnsItToo() {
        let viewModel = glancing(showingRecent: true)
        defer { viewModel.stage(phase: .closed, activity: .idle) }
        NoticeAction(title: "Show", kind: .showUsage).perform(in: viewModel, fromRecent: true)
        #expect(viewModel.glanceContent == .usage)
        #expect(!viewModel.isShowingRecent)
    }

    @Test func aButtonOnTheNoticeLeavesTheGlanceOpen() {
        let viewModel = glancing()
        defer { viewModel.stage(phase: .closed, activity: .idle) }
        NoticeAction(title: "Show", kind: .showUsage).perform(in: viewModel)
        #expect(viewModel.isGlancing)
        #expect(viewModel.glanceContent == .usage)
    }

    @Test func withTheSwitchOffThereIsNoRing() {
        let viewModel = glancing()
        AppSettings.shared.liveUsage = false
        defer {
            AppSettings.shared.liveUsage = true
            viewModel.stage(phase: .closed, activity: .idle)
        }
        viewModel.showUsage()
        #expect(viewModel.glanceContent != .usage)
    }

    @Test func theButtonKeepsForTheRecentList() {
        #expect([NoticeAction(title: "Show", kind: .showUsage)].keptForLater.count == 1)
    }

    @Test func closingForgetsIt() {
        let viewModel = glancing()
        viewModel.showUsage()
        viewModel.close()
        #expect(!viewModel.isShowingUsage)
    }
}
