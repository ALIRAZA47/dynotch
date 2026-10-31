import Darwin
import Foundation
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
    func add(_ request: SocketRequest) { lock.withLock { all.append(request) } }
}

private struct Scratch {
    let folder = NSTemporaryDirectory() + "dyn-" + UUID().uuidString.prefix(8)
    var path: String { folder + "/run/s.sock" }
}

struct CommandLineClientTests {
    /// Runs `arguments` against a server that says yes and remembers what it was asked.
    private func run(_ arguments: [String], answer: [String: Any] = ["ok": true]) throws -> (code: Int32, terminal: Terminal, request: SocketRequest?) {
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
        let terminal = Terminal()
        let code = CommandLineClient.run(arguments, io: terminal.io(socket: scratch.path))
        return (code, terminal, requests.last)
    }

    @Test func aPercentGoesToTheNotch() throws {
        let (code, _, request) = try run(["progress", "deploy", "40"])
        #expect(code == 0)
        #expect(request?.op == "progress")
        #expect(request?.string("key") == "deploy")
        #expect(request?.number("percent") == 40)
        #expect(request?.string("state") == nil)
    }

    @Test func aPercentSignIsFine() throws {
        #expect(try run(["progress", "deploy", "62.5%"]).request?.number("percent") == 62.5)
    }

    @Test func aNameAloneStartsItWithNoNumber() throws {
        let request = try run(["progress", "deploy"]).request
        #expect(request?.string("key") == "deploy")
        #expect(request?.number("percent") == nil)
    }

    @Test(arguments: [("done", "done"), ("finish", "done"), ("finished", "done"), ("DONE", "done"),
                      ("fail", "failed"), ("failed", "failed"), ("clear", "clear")])
    func wordsFinishIt(word: String, state: String) throws {
        #expect(try run(["progress", "deploy", word]).request?.string("state") == state)
    }

    @Test func optionsGoAlong() throws {
        let request = try run(["progress", "deploy", "40", "--detail", "Uploading", "--tint", "green", "--symbol", "bolt.fill",
                               "--quiet-after", "300"]).request
        #expect(request?.string("detail") == "Uploading")
        #expect(request?.string("tint") == "green")
        #expect(request?.string("symbol") == "bolt.fill")
        #expect(request?.number("quietAfter") == 300)
    }

    @Test func aFinishCanCarryAButton() throws {
        let request = try run(["progress", "deploy", "done", "--button", "Open", "--url", "https://example.com"]).request
        #expect(request?.string("button") == "Open")
        #expect(request?.string("url") == "https://example.com")
    }

    @Test(arguments: [["progress"], ["progress", "deploy", "soon"], ["progress", "deploy", "40", "extra"],
                      ["progress", "deploy", "--nope", "1"], ["progress", "deploy", "--detail"],
                      ["progress", "deploy", "--quiet-after", "soon"], ["progress", "deploy", "nan"], ["nonsense"], []])
    func wrongUseSaysHow(arguments: [String]) throws {
        let (code, terminal, request) = try run(arguments)
        #expect(code == CommandLineClient.usage)
        #expect(terminal.error.contains("Usage"))
        #expect(request == nil)
    }

    @Test func noExitCodeIsTwo() {
        // Exit 2 from a Claude Code hook blocks what it's hooked to.
        #expect(CommandLineClient.failure != 2)
        #expect(CommandLineClient.usage != 2)
    }

    @Test func aRefusalSaysWhy() throws {
        let (code, terminal, _) = try run(["progress", "deploy", "40"], answer: ["ok": false, "error": "No room"])
        #expect(code == CommandLineClient.failure)
        #expect(terminal.error == "dynotch: No room\n")
    }

    @Test func nothingRunningSaysSo() {
        let scratch = Scratch()
        let terminal = Terminal()
        let code = CommandLineClient.run(["status"], io: terminal.io(socket: scratch.path))
        #expect(code == CommandLineClient.failure)
        #expect(terminal.error == "dynotch: Dynotch isn't running\n")
        #expect(terminal.output.isEmpty)
    }

    @Test func statusJSONIsJSON() throws {
        let (code, terminal, request) = try run(["status", "--json"], answer: ["ok": true, "version": "1.5", "scripts": [["key": "deploy", "percent": 40]]])
        #expect(code == 0)
        #expect(request?.op == "status")
        let report = try JSONSerialization.jsonObject(with: Data(terminal.output.utf8)) as? [String: Any]
        #expect(report?["version"] as? String == "1.5")
        #expect((report?["scripts"] as? [[String: Any]])?.first?["percent"] as? Int == 40)
    }

    @Test func statusForReadingIsShort() throws {
        let (_, terminal, _) = try run(["status"], answer: [
            "ok": true, "version": "1.5", "notch": ["activity": "script", "heldNotices": 2],
            "scripts": [["key": "deploy", "percent": 40, "detail": "Uploading"], ["key": "backup", "percent": NSNull()]],
        ])
        #expect(terminal.output == "Dynotch 1.5\nClosed notch: script\nNotices waiting: 2\ndeploy 40% · Uploading\nbackup\n")
    }

    @Test func optionsAreSortedFromWords() {
        let parsed = CommandLineClient.parse(["a", "--x", "1", "b", "--json"], options: ["x"], flags: ["json"])
        #expect(parsed?.words == ["a", "b"])
        #expect(parsed?.options == ["x": "1"])
        #expect(parsed?.flags == ["json"])
    }
}

/// The real `scripts/dynotch` and the real binary, against a server in this test.
struct DynotchScriptTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let binary = root.appendingPathComponent(".build/debug/Dynotch").path
    private static var hasBinary: Bool { FileManager.default.isExecutableFile(atPath: binary) }

    private func dynotch(_ arguments: [String], socket: String) throws -> (code: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = Self.root.appendingPathComponent("scripts/dynotch")
        process.arguments = arguments
        process.environment = ["DYNOTCH_BIN": Self.binary, "DYNOTCH_SOCKET": socket, "PATH": "/usr/bin:/bin"]
        let output = Pipe(), error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    @Test(.enabled(if: hasBinary)) func progressReachesTheNotchThroughTheScript() throws {
        let scratch = Scratch()
        defer { try? FileManager.default.removeItem(atPath: scratch.folder) }
        let requests = Requests()
        let server = LocalSocketServer(path: scratch.path) { request, connection in
            requests.add(request)
            connection.reply(["ok": true])
        }
        try server.start()
        defer { server.stop() }
        let result = try dynotch(["progress", "deploy", "40", "--detail", "Up \"loading\" ünï"], socket: scratch.path)
        #expect(result.code == 0)
        #expect(requests.last?.string("key") == "deploy")
        #expect(requests.last?.number("percent") == 40)
        #expect(requests.last?.string("detail") == "Up \"loading\" ünï")
    }

    @Test(.enabled(if: hasBinary)) func withNothingListeningTheScriptSaysSo() throws {
        let scratch = Scratch()
        let result = try dynotch(["status", "--json"], socket: scratch.path)
        #expect(result.code == 1)
        #expect(result.output.isEmpty)
        #expect(result.error == "dynotch: Dynotch isn't running\n")
    }

    @Test func theScriptWontRunABinaryItFoundElsewhere() throws {
        // Not beside it inside an app, and not named by DYNOTCH_BIN: an older Dynotch would start up as a second copy.
        let process = Process()
        process.executableURL = Self.root.appendingPathComponent("scripts/dynotch")
        process.arguments = ["status"]
        process.environment = ["PATH": "/usr/bin:/bin"]
        let error = Pipe()
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 1)
        #expect(String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains("inside Dynotch.app"))
    }

    @Test func theUsageShowsEveryCommand() throws {
        let process = Process()
        process.executableURL = Self.root.appendingPathComponent("scripts/dynotch")
        process.arguments = ["--help"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(text.hasPrefix("dynotch notify TEXT") || text.contains("dynotch notify TEXT"))
        #expect(text.contains("dynotch progress NAME"))
        #expect(text.contains("dynotch status [--json]"))
        #expect(text.contains("line is keyed by NAME"))
    }
}

struct TerminalOriginTests {
    @Test func itComesFromTheEnvironment() {
        let origin = TerminalOrigin(environment: ["TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "w0t1p0:ABC",
                                                  "TTY": "/dev/ttys003", "PWD": "/tmp", "__CFBundleIdentifier": "com.googlecode.iterm2"])
        #expect(origin.program == "iTerm.app")
        #expect(origin.bundleID == "com.googlecode.iterm2")
        #expect(origin.sessionID == "w0t1p0:ABC")
        #expect(origin.tty == "/dev/ttys003")
        #expect(origin.folder == "/tmp")
    }

    @Test func aFolderGivenBeatsTheShells() {
        #expect(TerminalOrigin(environment: ["PWD": "/tmp"], folder: "/work").folder == "/work")
    }

    @Test func itSurvivesTheSocket() {
        let origin = TerminalOrigin(program: "ghostty", tty: "/dev/ttys001", folder: "/work")
        #expect(TerminalOrigin(fields: origin.fields) == origin)
    }
}
