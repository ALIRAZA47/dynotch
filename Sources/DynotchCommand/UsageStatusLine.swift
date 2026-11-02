import Darwin
import DynotchShared
import Foundation

/// `dynotch statusline`: Claude Code's status line. It passes the numbers on and prints a short line.
/// Claude Code runs it after every message and goes blank on a failure or on no output, so it's
/// quick, it always exits 0, and it has something to print whatever it was given.
enum UsageStatusLine {
    /// How long the notch gets to answer. The status line can't wait for a Dynotch that's stuck.
    static let socketPatience: TimeInterval = 0.25
    /// How long `--then` gets. Claude Code holds back the status line for as long as this runs.
    static let commandPatience: TimeInterval = 10
    /// What's printed when nothing in the input could be read.
    static let nothingRead = "Claude Code"

    static func run(_ arguments: [String], _ socket: SocketClient, _ io: CommandLineClient.IO) -> Int32 {
        let input = io.input()
        let reading = Reading(input)
        // First, so a slow `--then` can't hold up the numbers. Dynotch not running is no one's problem.
        if let request = reading.request { _ = try? socket.send(request, timeout: socketPatience) }
        let command = CommandLineClient.parse(arguments, options: ["then"])?.options["then"]
        let theirs = command.flatMap { output(of: $0, given: input, environment: io.environment) }
        io.output(theirs ?? reading.line() + "\n")
        return 0
    }

    /// What `command` prints when fed `input`, or nil if it prints nothing, won't start or takes too
    /// long. How it exits is its own business. Whoever runs the command chooses this, so it has to
    /// stay in a binary of its own: run from the app's, it would get every permission the app has.
    static func output(of command: String, given input: Data, environment: [String: String],
                       patience: TimeInterval = commandPatience) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = environment
        let feed = Pipe(), result = Pipe()
        process.standardInput = feed
        process.standardOutput = result
        guard (try? process.run()) != nil else { return nil }

        // Plenty of commands never read this, and writing to them mustn't end this process with SIGPIPE.
        let writer = feed.fileHandleForWriting
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        // Each on its own, so a command that prints before it reads can't wedge against a full pipe.
        // Real threads, as these block: a global queue's pool can run out while its callers wait on them.
        Thread.detachNewThread {
            try? writer.write(contentsOf: input)
            try? writer.close()
        }
        nonisolated(unsafe) var printed = Data()
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            printed = result.fileHandleForReading.readDataToEndOfFile()
            finished.signal()
        }
        guard finished.wait(timeout: .now() + patience) == .success else {
            process.terminate()
            return nil
        }
        let text = String(decoding: printed, as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// `dynotch status`'s line about the numbers, from what the store reports.
    static func summary(of report: [String: Any], now: Date = .now) -> String? {
        var parts: [String] = []
        for limit in UsageLimit.allCases {
            guard let window = report[limit.rawValue] as? [String: Any], let percent = window["percent"] as? Int else { continue }
            parts.append(limit.short(percent: percent, hasReset: window["hasReset"] as? Bool == true))
        }
        guard !parts.isEmpty else { return nil }
        if let seconds = report["secondsOld"] as? Int {
            parts.append("updated " + timeAgo(now.addingTimeInterval(-Double(seconds)), from: now))
        }
        return "Claude usage: " + parts.joined(separator: " · ")
    }

    /// What can be read of Claude Code's JSON: the model's name and the two windows. Everything else
    /// in there, a gateway's `spend_limit` included, is left alone.
    struct Reading {
        var model: String?
        private var used: [UsageLimit: Double] = [:]
        private var resets: [UsageLimit: Double] = [:]

        init(_ input: Data) {
            guard let fields = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { return }
            model = ((fields["model"] as? [String: Any])?["display_name"] as? String).flatMap(Self.oneLine)
            let limits = fields["rate_limits"] as? [String: Any]
            for limit in UsageLimit.allCases {
                let window = limits?[limit.statusLineKey] as? [String: Any]
                used[limit] = UsageWindow.number(window?["used_percentage"])
                resets[limit] = UsageWindow.number(window?["resets_at"])
            }
        }

        /// The `usage` request, or nil with nothing to send. Only numbers go, never who or where.
        var request: [String: Any]? {
            var request: [String: Any] = [:]
            for limit in UsageLimit.allCases {
                if let used = used[limit], let resets = resets[limit] {
                    request[limit.rawValue] = ["used": used, "resetsAt": resets]
                }
            }
            guard !request.isEmpty else { return nil }
            request["op"] = "usage"
            return request
        }

        /// "Opus 5.5 · 62% of 5 h · 9% of 7 d", with whatever couldn't be read left out.
        func line(at now: Date = .now) -> String {
            var parts = model.map { [$0] } ?? []
            for limit in UsageLimit.allCases {
                guard let percent = UsageWindow.percent(used[limit]) else { continue }
                let window = UsageWindow(used: used[limit], resetsAt: resets[limit], now: now)
                parts.append(limit.short(percent: percent, hasReset: window?.hasReset(at: now) ?? false))
            }
            return parts.isEmpty ? nothingRead : parts.joined(separator: " · ")
        }

        /// The name on a single line, without anything a terminal would act on.
        private static func oneLine(_ text: String) -> String? {
            let printable = text.components(separatedBy: .controlCharacters).joined()
            let trimmed = String(printable.trimmingCharacters(in: .whitespaces).prefix(40))
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}
