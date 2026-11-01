import Darwin
import Foundation

/// What came of running `gh`.
enum GitHubAnswer: Equatable {
    case finished(status: Int32, output: Data, error: String)
    /// `gh` isn't in any of the places it may be.
    case notInstalled
    /// It took too long, and was stopped.
    case timedOut

    /// What stands in the way of an answer.
    enum Problem: Equatable {
        case notInstalled
        case signedOut
        /// No such repository, or none this login can see.
        case notFound
        /// The network or GitHub, which can pass.
        case transient
    }

    /// Nil when `gh` did what it was asked. It exits with 4 when it needs a login, and a token GitHub
    /// no longer takes comes back as HTTP 401 instead.
    var problem: Problem? {
        switch self {
        case .notInstalled: return .notInstalled
        case .timedOut: return .transient
        case .finished(let status, _, let error):
            guard status != 0 else { return nil }
            let text = error.lowercased()
            if status == 4 || text.contains("gh auth login") || text.contains("http 401") { return .signedOut }
            return text.contains("http 404") ? .notFound : .transient
        }
    }

    /// What it printed, when it worked.
    var output: Data? {
        if case .finished(0, let output, _) = self { return output }
        return nil
    }
}

/// A workflow run, as `gh run list --json` gives it.
struct GitHubRun: Decodable, Equatable {
    /// What a finished run came to.
    enum Verdict: Equatable {
        case passed, failed, cancelled, skipped
    }

    let databaseId: Int
    let status: String
    /// Empty until it's over.
    var conclusion: String?
    var workflowName: String?
    var displayTitle: String?
    let headSha: String
    let url: String
    var createdAt: String?

    private static let dates = ISO8601DateFormatter()
    private static let longestName = 80

    var isOver: Bool { status == "completed" }
    var created: Date? { createdAt.flatMap(Self.dates.date(from:)) }

    /// A workflow's name is whatever its file says, so it's cleaned for one line of the notch.
    @MainActor
    var name: String {
        ScriptActivityStore.cleaned(workflowName, limit: Self.longestName)
            ?? ScriptActivityStore.cleaned(displayTitle, limit: Self.longestName) ?? "Workflow"
    }

    var phase: CIRun.Phase {
        switch status {
        case "queued", "requested", "pending": .queued
        case "waiting": .waiting
        default: .running
        }
    }

    /// Nil until it's over. Skipped and neutral runs are ones that decided nothing. A cancelled run
    /// didn't fail, but it didn't pass either, and that goes for a conclusion this doesn't know.
    var verdict: Verdict? {
        guard isOver else { return nil }
        switch conclusion {
        case "success": return .passed
        case "failure", "timed_out", "startup_failure", "action_required": return .failed
        case "skipped", "neutral": return .skipped
        default: return .cancelled
        }
    }

    /// What several finished runs come to: a failure outweighs a cancelled run, which outweighs a pass.
    static func verdict(of runs: [GitHubRun]) -> Verdict {
        let verdicts = runs.compactMap(\.verdict)
        for verdict in [Verdict.failed, .cancelled, .passed] where verdicts.contains(verdict) { return verdict }
        return .skipped
    }

    static func list(from data: Data) -> [GitHubRun]? {
        try? JSONDecoder().decode([GitHubRun].self, from: data)
    }
}

/// Runs `gh` for `CIMonitor`. Dynotch may hold Full Disk Access, and a child process inherits that,
/// so nothing a client says can pick what runs: `gh` comes only from `places`, never from a request
/// or anyone's PATH, its arguments go as an argv with no shell, and it gets a small environment of
/// its own. It uses the user's own `gh` login, and Dynotch stores no token.
enum GitHubCLI {
    typealias Runner = @Sendable ([String]) async -> GitHubAnswer

    /// Homebrew on Apple silicon and on Intel, MacPorts, the system, and nix-darwin.
    static let places = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/opt/local/bin/gh", "/usr/bin/gh",
                         "/run/current-system/sw/bin/gh"]
    /// A slow network shouldn't hold up the next look for long.
    static let timeout: TimeInterval = 20
    /// How long to wait after asking a stopped process to end, before ending it outright.
    private static let patience: TimeInterval = 2
    /// One at a time, whoever is asking.
    private static let queue = DispatchQueue(label: "app.dynotch.github", qos: .utility)

    static var environment: [String: String] {
        ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    }

    static func listArguments(repository: String, branch: String) -> [String] {
        ["run", "list", "--repo", repository, "--branch", branch, "--limit", "10", "--json",
         "databaseId,status,conclusion,workflowName,displayTitle,headSha,url,createdAt"]
    }

    static let reviewArguments = ["search", "prs", "--review-requested=@me", "--state=open", "--json", "number",
                                  "--limit", "100"]

    /// The first of `places` that can be trusted to run: anyone else who can write to it could run
    /// anything with what Dynotch holds.
    static func find(in places: [String] = places) -> String? {
        places.first { path in
            var info = stat()
            guard FileManager.default.isExecutableFile(atPath: path), stat(path, &info) == 0 else { return false }
            return info.st_mode & S_IFMT == S_IFREG && (info.st_uid == geteuid() || info.st_uid == 0)
                && info.st_mode & 0o022 == 0
        }
    }

    static func run(_ arguments: [String]) async -> GitHubAnswer {
        guard let path = find() else { return .notInstalled }
        return await run(path, arguments)
    }

    /// Runs off the main thread and off anything else that's waiting.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = timeout) async -> GitHubAnswer {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: runNow(executable, arguments, timeout: timeout)) }
        }
    }

    private static func runNow(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> GitHubAnswer {
        let output = Pipe(), error = Pipe()
        guard let process = spawn(executable, arguments, output: output, error: error) else {
            // `find` has just seen it there, so this is worth another try.
            return .finished(status: -1, output: Data(), error: "\(executable) didn't start")
        }
        try? output.fileHandleForWriting.close()
        try? error.fileHandleForWriting.close()
        let printed = PipeReader(output), complained = PipeReader(error)
        let exited = DispatchSemaphore(value: 0)
        let watcher = DispatchSource.makeProcessSource(identifier: process, eventMask: .exit, queue: .global(qos: .utility))
        watcher.setEventHandler { exited.signal() }
        watcher.resume()
        defer { watcher.cancel() }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            kill(process, SIGTERM)
            if exited.wait(timeout: .now() + patience) == .timedOut { kill(process, SIGKILL) }
            _ = reap(process)
            return .timedOut
        }
        return .finished(status: reap(process), output: printed.collected(),
                         error: String(decoding: complained.collected(), as: UTF8.self))
    }

    /// Starts `executable` with nothing of this process but the two pipes, and with macOS counting it
    /// as responsible for itself. A child otherwise uses the permissions of the app that started it,
    /// and `gh` usually sits in a folder this user can write to, so anything else running as them
    /// could swap it for something that reads what Dynotch has been allowed to, and have it run.
    static func spawn(_ executable: String, _ arguments: [String], output: Pipe, error: Pipe) -> pid_t? {
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              // From the root, as it has no claim on whatever folder this process started in.
              posix_spawn_file_actions_addchdir_np(&actions, "/") == 0,
              posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, 1) == 0,
              posix_spawn_file_actions_adddup2(&actions, error.fileHandleForWriting.fileDescriptor, 2) == 0 else { return nil }
        // Not in any header, though browsers and debuggers rely on it. Without it, `gh` would have all
        // that this app has been allowed, so no answer from it means `gh` doesn't start.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else { return nil }
        typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
        guard unsafeBitCast(symbol, to: Disclaim.self)(&attributes, 1) == 0 else { return nil }
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var process = pid_t()
        guard posix_spawn(&process, executable, &actions, &attributes, argv, envp) == 0 else { return nil }
        return process
    }

    /// Collects what's left of a process that has ended, and how it ended.
    private static func reap(_ process: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(process, &status, 0) == -1, errno == EINTR {}
        return status & 0x7F == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
    }
}

/// Reads a pipe as it fills, so a long answer can't stall the process writing it. On a thread of its
/// own: a busy queue can take longer to start one than the process takes to end.
private final class PipeReader: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var data = Data()

    init(_ pipe: Pipe) {
        Thread.detachNewThread { [self] in
            let read = pipe.fileHandleForReading.readDataToEndOfFile()
            lock.withLock { data = read }
            done.signal()
        }
    }

    /// What arrived. A short wait at most, in case something else still holds the pipe open.
    func collected() -> Data {
        _ = done.wait(timeout: .now() + 2)
        return lock.withLock { data }
    }
}
