import Foundation

/// `dynotch ci`: starts watching the runs for this branch. What's in the current folder is read here
/// in the client, as the person who typed the command: the app never runs git, or looks at a folder
/// a request names. It only hears a repository, a branch and a commit, and checks those.
enum CICommand {
    /// What a git repository says about itself.
    struct Checkout: Equatable {
        var repository: String?
        var branch: String?
        var sha: String?
    }

    /// Hosts that are GitHub without having to ask SSH.
    private static let gitHubHosts: Set = ["github.com", "www.github.com", "ssh.github.com"]
    private static let schemes: Set = ["https", "http", "ssh", "git", "git+ssh", "git+https"]

    /// `folder` and `resolveHost` let tests stand in for the terminal's folder and for SSH.
    static func run(_ arguments: [String], _ socket: SocketClient, _ io: CommandLineClient.IO,
                    folder: String = FileManager.default.currentDirectoryPath,
                    resolveHost: (String) -> String? = sshHost) -> Int32 {
        guard let parsed = CommandLineClient.parse(arguments, options: ["repo", "branch", "sha"], flags: ["stop"]),
              parsed.words.isEmpty else {
            io.error("Usage: dynotch ci [--repo OWNER/NAME] [--branch NAME] [--sha SHA] [--stop]\n")
            return CommandLineClient.usage
        }
        let options = parsed.options
        if parsed.flags.contains("stop") { return stop(options, socket, io) }

        let isNamed = ["repo", "branch", "sha"].allSatisfy { options[$0] != nil }
        let local = isNamed ? nil : checkout(in: folder, environment: io.environment, resolveHost: resolveHost)
        guard let repository = options["repo"] ?? local?.repository else {
            io.error(local == nil ? "dynotch: this folder isn't in a git repository\n" : "dynotch: this repository has no GitHub remote\n")
            return CommandLineClient.failure
        }
        guard let branch = options["branch"] ?? local?.branch else {
            io.error(local == nil ? "dynotch: name a branch with --branch\n" : "dynotch: this isn't on a branch, so name one with --branch\n")
            return CommandLineClient.failure
        }
        // Only this folder's commit if it's the same branch of the same repository.
        let sha = options["sha"] ?? (local?.repository == repository && local?.branch == branch ? local?.sha : nil)

        var request: [String: Any] = ["op": "ci", "repo": repository, "branch": branch]
        request["sha"] = sha
        guard CommandLineClient.send(request, socket, io) != nil else { return CommandLineClient.failure }
        io.output("Watching \(repository) on \(branch)" + (sha.map { " at \($0.prefix(7))" } ?? "") + "\n")
        return 0
    }

    private static func stop(_ options: [String: String], _ socket: SocketClient, _ io: CommandLineClient.IO) -> Int32 {
        var request: [String: Any] = ["op": "ci", "stop": true]
        request["repo"] = options["repo"]
        request["branch"] = options["branch"]
        guard let answer = CommandLineClient.send(request, socket, io) else { return CommandLineClient.failure }
        io.output(answer["stopped"] as? Int == 0 ? "Nothing was being watched\n" : "Stopped watching\n")
        return 0
    }

    /// What the repository at `folder` says, or nil if there isn't one. The remote is the one a push
    /// goes to, or else `origin`, or else the first that's on GitHub.
    static func checkout(in folder: String, environment: [String: String], resolveHost: (String) -> String?) -> Checkout? {
        func git(_ arguments: String...) -> String? {
            // Found as the shell would find it: this is the person's own command, in their own process.
            output(of: "/usr/bin/env", ["git"] + arguments, folder: folder, environment: environment)
        }
        guard git("rev-parse", "--git-dir") != nil else { return nil }
        let branch = git("symbolic-ref", "--quiet", "--short", "HEAD")
        var remotes = branch.map { name in
            [git("config", "--get", "branch.\(name).pushRemote"), git("config", "--get", "remote.pushDefault"),
             git("config", "--get", "branch.\(name).remote")].compactMap { $0 }
        } ?? []
        remotes.append("origin")
        remotes += git("remote")?.split(whereSeparator: \.isNewline).map(String.init) ?? []
        var checkout = Checkout(branch: branch, sha: git("rev-parse", "--verify", "--quiet", "HEAD"))
        for remote in remotes where checkout.repository == nil {
            checkout.repository = git("remote", "get-url", remote).flatMap { repository(fromRemote: $0, resolveHost: resolveHost) }
        }
        return checkout
    }

    /// `OWNER/NAME` from a remote's URL, if it's on GitHub. Any token in the URL stays out of it. An
    /// SSH host may be an alias, as in `git@gh-work:owner/name.git`, so `resolveHost` is asked.
    static func repository(fromRemote remote: String, resolveHost: (String) -> String?) -> String? {
        let authority: Substring, path: Substring, usesSSH: Bool
        if let separator = remote.range(of: "://") {
            let scheme = remote[..<separator.lowerBound].lowercased()
            let rest = remote[separator.upperBound...]
            guard schemes.contains(scheme), let slash = rest.firstIndex(of: "/") else { return nil }
            authority = rest[..<slash]
            path = rest[rest.index(after: slash)...]
            usesSSH = scheme.contains("ssh")
        } else {
            // user@host:owner/name, where a slash before the colon would make it a path on disk.
            guard let colon = remote.firstIndex(of: ":"), !remote[..<colon].contains("/") else { return nil }
            authority = remote[..<colon]
            path = remote[remote.index(after: colon)...]
            usesSSH = true
        }
        let hostAndPort = authority.split(separator: "@").last ?? ""
        let host = (hostAndPort.split(separator: ":").first ?? "").lowercased()
        guard gitHubHosts.contains(host) || (usesSSH && resolveHost(host).map { gitHubHosts.contains($0.lowercased()) } == true) else {
            return nil
        }
        var name = path.split(separator: "/").joined(separator: "/")
        if name.hasSuffix(".git") { name.removeLast(4) }
        return CIMonitor.isRepository(name) ? name : nil
    }

    /// Where SSH would really go for a host. `ssh -G` prints its settings and connects to nothing.
    static func sshHost(for alias: String) -> String? {
        guard isHostShaped(alias), let settings = output(of: "/usr/bin/ssh", ["-G", alias]) else { return nil }
        return settings.split(whereSeparator: \.isNewline).first { $0.hasPrefix("hostname ") }.map { String($0.dropFirst("hostname ".count)) }
    }

    /// A remote's URL comes from a repository that may not be the user's, and this goes to `ssh` as
    /// an argument, so it can't be anything that looks like an option.
    static func isHostShaped(_ text: String) -> Bool {
        guard let first = text.utf8.first, first != UInt8(ascii: "-"), first != UInt8(ascii: ".") else { return false }
        return text.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || "._-".utf8.contains(byte)
        }
    }

    /// What a command printed, or nil if it failed or printed nothing.
    private static func output(of executable: String, _ arguments: [String], folder: String? = nil,
                               environment: [String: String]? = nil) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let folder { process.currentDirectoryURL = URL(fileURLWithPath: folder) }
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
