import Darwin
import Foundation
import Testing
@testable import Dynotch
@testable import DynotchCommand
import DynotchShared

private final class Terminal {
    var output = ""
    var error = ""

    func io(environment: [String: String]) -> CommandLineClient.IO {
        var io = CommandLineClient.IO()
        io.output = { [unowned self] in output += $0 }
        io.error = { [unowned self] in error += $0 }
        io.environment = environment
        return io
    }
}

private final class Requests: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [SocketRequest] = []
    var last: SocketRequest? { lock.withLock { all.last } }
    func add(_ request: SocketRequest) { lock.withLock { all.append(request) } }
}

/// A folder of its own, for a socket and a repository to sit in.
private final class Scratch {
    let folder = NSTemporaryDirectory() + "dyn-" + UUID().uuidString.prefix(8)
    var socket: String { folder + "/run/s.sock" }
    var work: String { folder + "/work" }
    /// A home of its own and git with none of this Mac's settings, so nothing here reaches anything real.
    var environment: [String: String] {
        ["HOME": folder, "DYNOTCH_SOCKET": socket, "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
    }

    init() { try? FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(atPath: folder) }

    @discardableResult
    func git(_ arguments: String...) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: work)
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A repository with one commit on `main`, and `remote` as its origin if there is one.
    func repository(remote: String? = nil) {
        git("init", "-q", "-b", "main")
        if let remote { git("remote", "add", "origin", remote) }
        git("-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "--allow-empty", "-m", "One")
    }
}

/// `dynotch ci` in a scratch repository, against a server here that says yes.
struct CICommandTests {
    private func run(_ arguments: [String] = [], in scratch: Scratch, answer: [String: Any] = ["ok": true],
                     resolveHost: (String) -> String? = { _ in nil })
        throws -> (code: Int32, terminal: Terminal, request: SocketRequest?) {
        let requests = Requests()
        nonisolated(unsafe) let answer = answer
        let server = LocalSocketServer(path: scratch.socket) { request, connection in
            requests.add(request)
            connection.reply(answer)
        }
        try server.start()
        defer { server.stop() }
        let terminal = Terminal(), socket = SocketClient(path: scratch.socket)
        let code = CICommand.run(arguments, socket, terminal.io(environment: scratch.environment), folder: scratch.work,
                                 resolveHost: resolveHost)
        return (code, terminal, requests.last)
    }

    @Test func itWorksOutTheRepositoryBranchAndCommit() throws {
        let scratch = Scratch()
        scratch.repository(remote: "https://github.com/acme/app.git")
        let sha = scratch.git("rev-parse", "HEAD")
        let (code, terminal, request) = try run(in: scratch)
        #expect(code == 0)
        #expect(request?.op == "ci")
        #expect(request?.string("repo") == "acme/app")
        #expect(request?.string("branch") == "main")
        #expect(request?.string("sha") == sha)
        #expect(terminal.output == "Watching acme/app on main at \(sha.prefix(7))\n")
        #expect(terminal.error.isEmpty)
    }

    @Test func anSSHAliasIsLookedUp() throws {
        let scratch = Scratch()
        scratch.repository(remote: "git@gh-work:acme/app.git")
        let (code, _, request) = try run(in: scratch, resolveHost: { $0 == "gh-work" ? "github.com" : nil })
        #expect(code == 0)
        #expect(request?.string("repo") == "acme/app")
    }

    @Test func theBranchIsTheOneCheckedOut() throws {
        let scratch = Scratch()
        scratch.repository(remote: "git@github.com:acme/app.git")
        scratch.git("checkout", "-q", "-b", "fix/login")
        #expect(try run(in: scratch).request?.string("branch") == "fix/login")
    }

    @Test func theRemoteABranchPushesToComesFirst() throws {
        let scratch = Scratch()
        scratch.repository(remote: "git@github.com:acme/app.git")
        scratch.git("remote", "add", "fork", "git@github.com:me/app.git")
        scratch.git("config", "branch.main.pushRemote", "fork")
        #expect(try run(in: scratch).request?.string("repo") == "me/app")
    }

    @Test func anyRemoteOnGitHubWillDo() throws {
        let scratch = Scratch()
        scratch.repository(remote: "git@gitlab.com:acme/app.git")
        scratch.git("remote", "add", "mirror", "https://github.com/acme/mirror")
        #expect(try run(in: scratch).request?.string("repo") == "acme/mirror")
    }

    @Test func outsideARepositoryItSaysSo() throws {
        let scratch = Scratch()
        let (code, terminal, request) = try run(in: scratch)
        #expect(code == CommandLineClient.failure)
        #expect(terminal.error == "dynotch: this folder isn't in a git repository\n")
        #expect(terminal.output.isEmpty)
        #expect(request == nil)
    }

    @Test func withNoRemoteItSaysSo() throws {
        let scratch = Scratch()
        scratch.repository()
        let (code, terminal, request) = try run(in: scratch)
        #expect(code == CommandLineClient.failure)
        #expect(terminal.error == "dynotch: this repository has no GitHub remote\n")
        #expect(request == nil)
    }

    @Test func aRemoteElsewhereDoesntCount() throws {
        let scratch = Scratch()
        scratch.repository(remote: "https://gitlab.com/acme/app.git")
        let (code, terminal, _) = try run(in: scratch)
        #expect(code == CommandLineClient.failure)
        #expect(terminal.error == "dynotch: this repository has no GitHub remote\n")
    }

    @Test func offABranchItAsksForOne() throws {
        let scratch = Scratch()
        scratch.repository(remote: "https://github.com/acme/app")
        scratch.git("checkout", "-q", "--detach")
        let (code, terminal, _) = try run(in: scratch)
        #expect(code == CommandLineClient.failure)
        #expect(terminal.error == "dynotch: this isn't on a branch, so name one with --branch\n")
        #expect(try run(["--branch", "main"], in: scratch).code == 0)
    }

    @Test func withDynotchNotRunningItSaysSo() {
        let scratch = Scratch()
        scratch.repository(remote: "https://github.com/acme/app")
        let terminal = Terminal()
        let code = CICommand.run([], SocketClient(path: scratch.socket), terminal.io(environment: scratch.environment), folder: scratch.work)
        #expect(code == CommandLineClient.failure)
        #expect(terminal.error == "dynotch: Dynotch isn't running\n")
        #expect(terminal.output.isEmpty)
    }

    @Test func aRefusalSaysWhy() throws {
        let scratch = Scratch()
        let (code, terminal, _) = try run(["--repo", "a/b", "--branch", "main", "--sha", "abcdef1"], in: scratch,
                                          answer: ["ok": false, "error": "No room"])
        #expect(code == CommandLineClient.failure)
        #expect(terminal.error == "dynotch: No room\n")
    }

    @Test func optionsNeedNoRepository() throws {
        let scratch = Scratch()
        let (code, terminal, request) = try run(["--repo", "a/b", "--branch", "dev", "--sha", "abcdef1234"], in: scratch)
        #expect(code == 0)
        #expect(request?.string("repo") == "a/b")
        #expect(request?.string("branch") == "dev")
        #expect(request?.string("sha") == "abcdef1234")
        #expect(terminal.output == "Watching a/b on dev at abcdef1\n")
    }

    @Test func aRepositoryNamedWithNoBranchNeedsOne() throws {
        let scratch = Scratch()
        let (code, terminal, _) = try run(["--repo", "a/b"], in: scratch)
        #expect(code == CommandLineClient.failure)
        #expect(terminal.error == "dynotch: name a branch with --branch\n")
    }

    @Test func anotherBranchDoesntBorrowThisCommit() throws {
        let scratch = Scratch()
        scratch.repository(remote: "https://github.com/acme/app")
        let (_, terminal, request) = try run(["--branch", "dev"], in: scratch)
        #expect(request?.string("branch") == "dev")
        #expect(request?.string("sha") == nil)
        #expect(terminal.output == "Watching acme/app on dev\n")
    }

    @Test func anotherRepositoryDoesntBorrowThisCommit() throws {
        let scratch = Scratch()
        scratch.repository(remote: "https://github.com/acme/app")
        let request = try run(["--repo", "acme/other"], in: scratch).request
        #expect(request?.string("repo") == "acme/other")
        #expect(request?.string("branch") == "main")
        #expect(request?.string("sha") == nil)
    }

    @Test func stoppingAsksForNoRepository() throws {
        let scratch = Scratch()
        let (code, terminal, request) = try run(["--stop"], in: scratch, answer: ["ok": true, "stopped": 2])
        #expect(code == 0)
        #expect(request?.fields["stop"] as? Bool == true)
        #expect(request?.string("repo") == nil)
        #expect(terminal.output == "Stopped watching\n")
    }

    @Test func stoppingNothingSaysSo() throws {
        #expect(try run(["--stop"], in: Scratch(), answer: ["ok": true, "stopped": 0]).terminal.output == "Nothing was being watched\n")
    }

    @Test func stoppingCanBeNarrowed() throws {
        let request = try run(["--stop", "--repo", "a/b", "--branch", "dev"], in: Scratch()).request
        #expect(request?.string("repo") == "a/b")
        #expect(request?.string("branch") == "dev")
    }

    @Test(arguments: [["word"], ["--nope"], ["--repo"], ["--branch"], ["--sha"], ["--stop", "word"]])
    func wrongUseSaysHow(arguments: [String]) throws {
        let (code, terminal, request) = try run(arguments, in: Scratch())
        #expect(code == CommandLineClient.usage)
        #expect(terminal.error.contains("dynotch ci [--repo OWNER/NAME]"))
        #expect(request == nil)
    }
}

struct RemoteURLTests {
    private func parsed(_ remote: String, alias: String? = nil) -> String? {
        CICommand.repository(fromRemote: remote) { $0 == alias ? "github.com" : nil }
    }

    @Test(arguments: [
        ("git@github.com:acme/app.git", "acme/app"),
        ("git@github.com:acme/app", "acme/app"),
        ("git@github.com:acme/app.git/", "acme/app"),
        ("github.com:acme/app.git", "acme/app"),
        ("https://github.com/acme/app.git", "acme/app"),
        ("https://github.com/acme/app", "acme/app"),
        ("https://github.com/acme/app/", "acme/app"),
        ("https://www.github.com/acme/app.git", "acme/app"),
        ("HTTPS://GitHub.com/acme/app.git", "acme/app"),
        ("http://github.com/acme/app.git", "acme/app"),
        ("ssh://git@github.com/acme/app.git", "acme/app"),
        ("ssh://git@ssh.github.com:443/acme/app.git", "acme/app"),
        ("git://github.com/acme/app.git", "acme/app"),
        ("git+ssh://git@github.com/acme/app.git", "acme/app"),
        ("https://x-access-token:SECRET@github.com/acme/app.git", "acme/app"),
        ("git@github.com:my.org/my_app-2.js.git", "my.org/my_app-2.js"),
    ])
    func aGitHubRemoteGivesItsRepository(remote: String, repository: String) {
        #expect(parsed(remote) == repository)
    }

    @Test func aTokenInTheURLStaysOutOfIt() throws {
        #expect(try #require(parsed("https://user:SECRET@github.com/acme/app.git")).contains("SECRET") == false)
    }

    @Test(arguments: ["git@gh-khan47:ALIRAZA47/dynotch.git", "gh-khan47:ALIRAZA47/dynotch.git",
                      "ssh://git@gh-khan47/ALIRAZA47/dynotch.git", "ssh://git@gh-khan47:2222/ALIRAZA47/dynotch"])
    func anSSHAliasForGitHubCounts(remote: String) {
        #expect(parsed(remote, alias: "gh-khan47") == "ALIRAZA47/dynotch")
    }

    @Test func anAliasForSomewhereElseDoesnt() {
        #expect(parsed("git@gh-work:acme/app.git") == nil)
    }

    @Test func anHTTPSHostIsNeverAnAlias() {
        #expect(parsed("https://gh-work/acme/app.git", alias: "gh-work") == nil)
    }

    @Test(arguments: ["https://gitlab.com/acme/app.git", "git@gitlab.com:acme/app.git", "https://github.com.evil.example/acme/app",
                      "https://evil.example/github.com/acme/app", "https://github.com@evil.example/acme/app", "/srv/git/app.git", "../app.git", "./a:b/c.git",
                      "file:///srv/git/acme/app.git", "ftp://github.com/acme/app.git", "git@github.com:acme", "git@github.com:acme/app/extra.git",
                      "https://github.com/acme", "https://github.com", "git@github.com:../../etc.git", "git@github.com:acme/a b.git", ""])
    func anythingElseIsNot(remote: String) {
        #expect(parsed(remote) == nil)
    }

    @Test(arguments: ["gh-khan47", "github.com", "a.b-c_d"])
    func aHostIsTaken(host: String) {
        #expect(CICommand.isHostShaped(host))
    }

    @Test(arguments: ["", "-oProxyCommand=evil", "-G", ".hidden", "a b", "a;b", "a$(b)", "a\nb"])
    func whatCouldPassForAnOptionIsNot(host: String) {
        #expect(!CICommand.isHostShaped(host))
        #expect(CICommand.sshHost(for: host) == nil)
    }
}

/// The real `scripts/dynotch` and the real binary, in a scratch repository.
struct CIScriptTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let binary = root.appendingPathComponent(".build/debug/DynotchCommand").path
    private static var hasBinary: Bool { FileManager.default.isExecutableFile(atPath: binary) }

    private func dynotch(_ arguments: [String], in scratch: Scratch) throws -> (code: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = Self.root.appendingPathComponent("scripts/dynotch")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: scratch.work)
        process.environment = scratch.environment.merging(["DYNOTCH_BIN": Self.binary]) { $1 }
        let output = Pipe(), error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    @Test(.enabled(if: hasBinary)) func ciReachesTheNotchThroughTheScript() throws {
        let scratch = Scratch()
        scratch.repository(remote: "git@github.com:acme/app.git")
        let requests = Requests()
        let server = LocalSocketServer(path: scratch.socket) { request, connection in
            requests.add(request)
            connection.reply(["ok": true])
        }
        try server.start()
        defer { server.stop() }
        let result = try dynotch(["ci"], in: scratch)
        #expect(result.code == 0)
        #expect(result.output.hasPrefix("Watching acme/app on main at "))
        #expect(requests.last?.string("repo") == "acme/app")
        #expect(requests.last?.string("branch") == "main")
        #expect(requests.last?.string("sha") == scratch.git("rev-parse", "HEAD"))
    }

    @Test(.enabled(if: hasBinary)) func withNothingListeningTheScriptSaysSo() throws {
        let scratch = Scratch()
        scratch.repository(remote: "git@github.com:acme/app.git")
        let result = try dynotch(["ci"], in: scratch)
        #expect(result.code == 1)
        #expect(result.error == "dynotch: Dynotch isn't running\n")
    }

    @Test(.enabled(if: hasBinary)) func outsideARepositoryTheScriptSaysSo() throws {
        let result = try dynotch(["ci"], in: Scratch())
        #expect(result.code == 1)
        #expect(result.error == "dynotch: this folder isn't in a git repository\n")
    }

    @Test func theUsageShowsIt() throws {
        let process = Process()
        process.executableURL = Self.root.appendingPathComponent("scripts/dynotch")
        process.arguments = ["--help"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(text.contains("dynotch ci [--repo OWNER/NAME] [--branch NAME] [--sha SHA] [--stop]"))
        #expect(text.contains("line is keyed by NAME"))
    }
}

/// The real zsh file in a real interactive zsh with no settings of the user's, in a scratch folder
/// that's also its home. `git`, `gh`, `sudo` and `dynotch` are all fakes there, and the file is a copy
/// with no `dynotch` beside it, so nothing real runs, is pushed, or hears about it.
struct PushHookTests {
    private static let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("scripts/notify-long-commands.zsh")

    private final class Shell {
        let folder = NSTemporaryDirectory() + "dyn-zsh-" + UUID().uuidString.prefix(8)
        var bin: String { folder + "/bin" }
        var calls: String { folder + "/calls" }

        init(hasDynotch: Bool = true, hasGitHub: Bool = true) throws {
            try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
            // A copy with no dynotch beside it, so the one on the PATH is the one it finds.
            try FileManager.default.copyItem(at: PushHookTests.script, to: URL(fileURLWithPath: folder + "/hook.zsh"))
            try fake("git", "case \"$*\" in *--fail*) exit 1 ;; esac\nexit 0")
            try fake("sudo", "exec \"$@\"")
            if hasGitHub { try fake("gh", "exit 0") }
            if hasDynotch { try fake("dynotch", "echo \"$*\" >> '\(calls)'") }
        }

        deinit { try? FileManager.default.removeItem(atPath: folder) }

        private func fake(_ name: String, _ body: String) throws {
            let path = bin + "/" + name
            try Data("#!/bin/sh\n\(body)\n".utf8).write(to: URL(fileURLWithPath: path))
            chmod(path, 0o755)
        }

        /// Types `lines` at a prompt, and says what came out.
        @discardableResult
        func type(_ lines: [String], environment: [String: String] = [:]) throws -> (code: Int32, output: String, error: String) {
            let session = (["PS1=", "source \(folder)/hook.zsh"] + lines + ["exit"]).joined(separator: "\n") + "\n"
            let path = folder + "/session.zsh"
            try Data(session.utf8).write(to: URL(fileURLWithPath: path))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-f", "-i"]
            process.currentDirectoryURL = URL(fileURLWithPath: folder)
            process.environment = ["HOME": folder, "PATH": bin + ":/usr/bin:/bin"].merging(environment) { $1 }
            process.standardInput = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            let output = Pipe(), error = Pipe()
            process.standardOutput = output
            process.standardError = error
            try process.run()
            let printed = output.fileHandleForReading.readDataToEndOfFile()
            let complained = error.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: printed, as: UTF8.self), String(decoding: complained, as: UTF8.self))
        }

        /// What `dynotch` was asked, once `count` calls are in and a moment's gone by for any more to land.
        func called(atLeast count: Int = 1) async -> [String] {
            func lines() -> [String] {
                (try? String(contentsOfFile: calls, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
            }
            for _ in 0..<500 where lines().count < count { try? await Task.sleep(for: .milliseconds(10)) }
            try? await Task.sleep(for: .milliseconds(120))
            return lines()
        }
    }

    @Test(arguments: ["git push", "git push origin main", "git push -u origin HEAD", "git commit -m wip && git push", "git add . ; git push",
                      "env FOO=1 git push", "FOO=1 git push", "nice git push", "nohup git push", "time git push", "command git push",
                      "noglob git push", "sudo git push", "git -c core.foo=bar push", "git --no-pager push", "git -C . push",
                      "gp", "echo hello | cat && git push"])
    func aPushIsFollowed(line: String) async throws {
        let shell = try Shell()
        try shell.type(["alias gp='git push'", line])
        #expect(await shell.called() == ["ci"])
    }

    @Test(arguments: ["git status", "git pull", "echo git push", "git log push", "git push --fail", "git push origin main --fail",
                      "git push --dry-run", "git push -n", "git push origin --delete old", "git push -d origin old", "git push --help",
                      "pushd .", "git stash push", "gitpush"])
    func nothingElseIs(line: String) async throws {
        let shell = try Shell()
        // A push in the same session, so there's something to wait for.
        try shell.type([line, "git push"])
        #expect(await shell.called() == ["ci"])
    }

    @Test func aPushDoesntFollowTwiceOnAnEmptyLine() async throws {
        let shell = try Shell()
        try shell.type(["git push", "", "", "echo done"])
        #expect(await shell.called() == ["ci"])
    }

    @Test func aPushIsQuickerThanTheLongCommandThreshold() async throws {
        let shell = try Shell()
        try shell.type(["git push"], environment: ["DYNOTCH_LONG_COMMAND": "3600"])
        #expect(await shell.called() == ["ci"])
    }

    @Test func itCanBeTurnedOff() async throws {
        let shell = try Shell()
        try shell.type(["git push"], environment: ["DYNOTCH_CI_AFTER_PUSH": "0"])
        #expect(await shell.called(atLeast: 0).isEmpty)
    }

    @Test func itSurvivesDynotchBeingMissing() throws {
        let shell = try Shell(hasDynotch: false)
        let quiet = try shell.type(["git status"])
        let result = try shell.type(["git push"])
        #expect(result.code == 0)
        #expect(result.error == quiet.error)
        #expect(result.output.isEmpty)
    }

    @Test func itLeavesPeopleWithoutGhAlone() async throws {
        let shell = try Shell(hasGitHub: false)
        try shell.type(["git push"])
        #expect(await shell.called(atLeast: 0).isEmpty)
    }

    @Test func itPrintsNothing() async throws {
        let shell = try Shell()
        let quiet = try shell.type(["git status"])
        let result = try shell.type(["git push"])
        #expect(result.code == 0)
        // The same as any other line: no job number, and nothing from `dynotch`.
        #expect(result.error == quiet.error)
        #expect(result.output.isEmpty)
    }

    @Test func theLongCommandNoticeGoesOnBesideIt() async throws {
        let shell = try Shell()
        try shell.type(["git push"], environment: ["DYNOTCH_LONG_COMMAND": "0"])
        let calls = await shell.called(atLeast: 2)
        #expect(calls.contains("ci"))
        #expect(calls.contains { $0.hasPrefix("notify Done --detail git") })
    }

    @Test func theLongCommandNoticeSaysFailedAndNothingFollows() async throws {
        let shell = try Shell()
        try shell.type(["git push --fail"], environment: ["DYNOTCH_LONG_COMMAND": "0"])
        let calls = await shell.called()
        #expect(calls.count == 1)
        #expect(calls.first?.hasPrefix("notify Failed") == true)
    }
}
