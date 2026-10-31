import Foundation

/// `Dynotch --cli …`: the part of the `dynotch` command that has to hear back from the notch.
/// `scripts/dynotch` comes here for those and keeps to `dynotch://` links for the rest. This runs
/// before anything of the app starts, and it never touches the app's settings.
enum CommandLineClient {
    /// What a command reads and writes, so tests can stand in for the terminal. These are the calls
    /// that throw: the older ones raise an exception that ends the process if either end is closed.
    struct IO {
        var input: () -> Data = { (try? FileHandle.standardInput.readToEnd()) ?? Data() }
        var output: (String) -> Void = { try? FileHandle.standardOutput.write(contentsOf: Data($0.utf8)) }
        var error: (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }
        var environment = ProcessInfo.processInfo.environment
    }

    /// Failed, or not running. Not 2: to a Claude Code hook that means something else entirely.
    static let failure: Int32 = 1
    /// Used wrongly, as in sysexits.h.
    static let usage: Int32 = 64

    static func run(_ arguments: [String], io: IO = IO()) -> Int32 {
        guard let command = arguments.first else { return wrongUse(io) }
        let rest = Array(arguments.dropFirst())
        let socket = SocketClient(path: SocketLocation.current(environment: io.environment))
        switch command {
        case "progress": return progress(rest, socket, io)
        case "status": return status(rest, socket, io)
        case "hook": return AgentHook.run(rest, socket, io)
        case "statusline": return UsageStatusLine.run(rest, socket, io)
        case "ci": return CICommand.run(rest, socket, io)
        default: return wrongUse(io)
        }
    }

    /// Sorts `--name value` pairs from plain words, and refuses an option it wasn't told about.
    static func parse(_ arguments: [String], options allowed: Set<String>, flags: Set<String> = [])
        -> (words: [String], options: [String: String], flags: Set<String>)? {
        var words: [String] = [], options: [String: String] = [:], found = Set<String>()
        var rest = arguments[...]
        while let word = rest.popFirst() {
            guard word.hasPrefix("--") else {
                words.append(word)
                continue
            }
            let name = String(word.dropFirst(2))
            if flags.contains(name) {
                found.insert(name)
            } else if allowed.contains(name), let value = rest.popFirst() {
                options[name] = value
            } else {
                return nil
            }
        }
        return (words, options, found)
    }

    /// Sends a request, and says what went wrong if it didn't work.
    static func send(_ request: [String: Any], _ socket: SocketClient, _ io: IO) -> [String: Any]? {
        do {
            let answer = try socket.send(request)
            if answer["ok"] as? Bool == true { return answer }
            io.error("dynotch: \(answer["error"] as? String ?? "That didn't work")\n")
        } catch SocketClient.Failure.notRunning {
            io.error("dynotch: Dynotch isn't running\n")
        } catch {
            io.error("dynotch: no answer from Dynotch\n")
        }
        return nil
    }

    // MARK: progress

    private static func progress(_ arguments: [String], _ socket: SocketClient, _ io: IO) -> Int32 {
        let names: Set = ["detail", "symbol", "tint", "quiet-after", "button", "url"]
        guard let parsed = parse(arguments, options: names), let key = parsed.words.first, parsed.words.count <= 2 else {
            return wrongUse(io)
        }
        var request: [String: Any] = ["op": "progress", "key": key]
        for name in ["detail", "symbol", "tint", "button", "url"] { request[name] = parsed.options[name] }
        if let seconds = parsed.options["quiet-after"] {
            guard let value = Double(seconds), value.isFinite else { return wrongUse(io) }
            request["quietAfter"] = value
        }
        if let word = parsed.words.dropFirst().first {
            switch word.lowercased() {
            case "done", "finish", "finished": request["state"] = "done"
            case "fail", "failed": request["state"] = "failed"
            case "clear": request["state"] = "clear"
            default:
                let digits = word.hasSuffix("%") ? String(word.dropLast()) : word
                guard let percent = Double(digits), percent.isFinite else { return wrongUse(io) }
                request["percent"] = percent
            }
        }
        return send(request, socket, io) == nil ? failure : 0
    }

    // MARK: status

    private static func status(_ arguments: [String], _ socket: SocketClient, _ io: IO) -> Int32 {
        guard let parsed = parse(arguments, options: [], flags: ["json"]), parsed.words.isEmpty else { return wrongUse(io) }
        guard let report = send(["op": "status"], socket, io) else { return failure }
        if parsed.flags.contains("json") {
            let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
            io.output((data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}") + "\n")
        } else {
            io.output(summary(of: report))
        }
        return 0
    }

    /// `dynotch status` for reading.
    static func summary(of report: [String: Any]) -> String {
        var lines = ["Dynotch \(report["version"] as? String ?? "")"]
        if let notch = report["notch"] as? [String: Any] {
            lines.append("Closed notch: \(notch["activity"] as? String ?? "idle")")
            if let held = notch["heldNotices"] as? Int, held > 0 { lines.append("Notices waiting: \(held)") }
        }
        if let agents = report["agents"] as? [String: Any], agents["sessions"] as? Int ?? 0 > 0 {
            let states = ["waiting", "working", "ready", "done"].compactMap { state in
                (agents[state] as? Int).flatMap { $0 > 0 ? "\($0) \(state)" : nil }
            }
            lines.append("Claude Code: " + states.joined(separator: ", "))
        }
        for script in report["scripts"] as? [[String: Any]] ?? [] {
            var line = script["key"] as? String ?? ""
            if let percent = script["percent"] as? Int { line += " \(percent)%" }
            if let detail = script["detail"] as? String { line += " · \(detail)" }
            lines.append(line)
        }
        let ci = report["ci"] as? [String: Any]
        for watch in ci?["watching"] as? [[String: Any]] ?? [] {
            var line = "CI: \(watch["repository"] as? String ?? "") on \(watch["branch"] as? String ?? "")"
            if let workflow = watch["workflow"] as? String { line += " · \(workflow)" }
            lines.append(line)
        }
        if let reviews = ci?["reviews"] as? Int, reviews > 0 { lines.append("Reviews waiting: \(reviews)") }
        if let usage = report["usage"] as? [String: Any], let line = UsageStatusLine.summary(of: usage) { lines.append(line) }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func wrongUse(_ io: IO) -> Int32 {
        io.error("Usage: dynotch progress NAME [PERCENT|done|fail|clear] [--detail TEXT] [--symbol SF_SYMBOL] [--tint COLOR]\n"
            + "                        [--quiet-after SECONDS] [--button TITLE --url https://...]\n"
            + "       dynotch status [--json]\n"
            + "       dynotch ci [--repo OWNER/NAME] [--branch NAME] [--sha SHA] [--stop]\n")
        return usage
    }
}
