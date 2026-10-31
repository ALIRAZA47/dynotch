import Darwin
import Foundation

/// The things the Terminal setup card can put in place. Each one needs the one before it to work,
/// apart from the long-command hook, which only needs the app.
enum SetupItem: String, CaseIterable, Identifiable {
    case command, longCommands, claudeHooks, claudeStatusLine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .command: "The dynotch command"
        case .longCommands: "Long commands"
        case .claudeHooks: "Claude Code sessions"
        case .claudeStatusLine: "Claude usage"
        }
    }

    var detail: String {
        switch self {
        case .command: "Use dynotch from any terminal"
        case .longCommands: "A notice when a shell command that ran for a while finishes"
        case .claudeHooks: "Sessions in the notch, and approvals you can answer from it"
        case .claudeStatusLine: "A status line that feeds the usage ring"
        }
    }

    var symbol: String {
        switch self {
        case .command: "terminal.fill"
        case .longCommands: "hourglass"
        case .claudeHooks: "sparkles"
        case .claudeStatusLine: "gauge.with.dots.needle.67percent"
        }
    }

    /// These run the link in ~/.local/bin.
    var needsCommand: Bool { self == .claudeHooks || self == .claudeStatusLine }
}

/// Reads and changes the files Terminal setup is about, all of it inside `home`, so tests can hand it
/// a scratch folder. Nothing here runs by itself: changes come from a click in the card, each one
/// shown first, and whatever it adds it can take out again without touching what was beside it.
struct TerminalSetup {
    enum State: Equatable {
        case notInstalled
        case installed
        /// Some of it is there, or it's left over from where the app used to be.
        case outOfDate
        /// Something else is in its place, and it stays there.
        case blocked(String)
    }

    enum Failure: Error, Equatable {
        /// A file isn't what it should be, so it was left alone.
        case blocked(String)
        /// A file changed after its changes were shown.
        case changedSinceReview
        case couldNotWrite(String)
    }

    /// One change, as the card shows it.
    struct Change: Equatable, Identifiable {
        let item: SetupItem
        /// What happens, in a line.
        let summary: String
        /// The text going in or coming out.
        let text: String

        var id: String { "\(item.rawValue)-\(summary)" }
    }

    static let blockStart = "# >>> Dynotch >>>"
    static let blockEnd = "# <<< Dynotch <<<"

    /// The home folder, the real one for the app.
    let home: URL
    /// `Dynotch.app/Contents/Resources`.
    let resources: URL

    private var manager: FileManager { .default }

    var linkURL: URL { home.appendingPathComponent(".local/bin/dynotch") }
    var zshrcURL: URL { home.appendingPathComponent(".zshrc") }
    var settingsURL: URL { home.appendingPathComponent(".claude/settings.json") }
    var backupsURL: URL { home.appendingPathComponent("Library/Application Support/Dynotch/setup-backups") }
    private var commandInApp: URL { resources.appendingPathComponent("dynotch") }
    private var longCommandHook: URL { resources.appendingPathComponent("notify-long-commands.zsh") }

    /// What goes in `settings.json`, through the link so moving the app only means fixing the link.
    var hookCommand: String { "\(Self.quoted(linkURL.path)) hook" }
    var statusLineCommand: String { "\(Self.quoted(linkURL.path)) statusline" }

    /// Dynotch can only point at itself from a place it's going to stay.
    static func problem(with app: Bundle) -> String? {
        let path = app.bundlePath
        if !path.hasSuffix(".app") { return "This only works from Dynotch.app." }
        if path.hasPrefix("/Volumes/") { return "Move Dynotch to Applications first." }
        if path.contains("/AppTranslocation/") { return "Move Dynotch to Applications and open it from there first." }
        return nil
    }

    // MARK: State

    func state(of item: SetupItem) -> State {
        switch item {
        case .command: commandState
        case .longCommands: longCommandsState
        case .claudeHooks: hooksState
        case .claudeStatusLine: statusLineState
        }
    }

    private var commandState: State {
        guard let target = try? manager.destinationOfSymbolicLink(atPath: linkURL.path) else {
            guard exists(linkURL) else { return .notInstalled }
            return .blocked("~/.local/bin/dynotch is something else, so it stays.")
        }
        if target == commandInApp.path { return .installed }
        return Self.isDynotchCommand(target) ? .outOfDate : .blocked("~/.local/bin/dynotch points somewhere else, so it stays.")
    }

    private var longCommandsState: State {
        guard exists(zshrcURL) else { return .notInstalled }
        guard let text = read(zshrcURL) else { return .blocked("~/.zshrc can't be read.") }
        guard let block = Self.block(in: text) else {
            return text.contains(Self.blockStart) || text.contains(Self.blockEnd)
                ? .blocked("The Dynotch block in ~/.zshrc has lost a marker, so it stays.") : .notInstalled
        }
        return String(text[block]) == zshBlock(text: text) ? .installed : .outOfDate
    }

    private var hooksState: State {
        if let blocked = commandInTheWay { return blocked }
        guard exists(settingsURL) else { return .notInstalled }
        guard let settings = try? settingsDocument() else { return Self.unreadableSettings }
        let present = AgentHook.events.filter { Self.hasCommand(hookCommand, in: settings["hooks"]?[$0.name]) }.count
        return present == 0 ? .notInstalled : present == AgentHook.events.count ? .installed : .outOfDate
    }

    private var statusLineState: State {
        if let blocked = commandInTheWay { return blocked }
        guard exists(settingsURL) else { return .notInstalled }
        guard let settings = try? settingsDocument() else { return Self.unreadableSettings }
        guard let line = settings["statusLine"] else { return .notInstalled }
        return line["command"]?.stringValue == statusLineCommand
            ? .installed : .blocked("You have a status line already, so it stays.")
    }

    private static let unreadableSettings = State.blocked("~/.claude/settings.json isn't valid JSON, so it stays.")

    /// Hooks run the link, so with something else at that path they'd run that. What's already
    /// installed can still come out.
    private var commandInTheWay: State? {
        guard case .blocked = commandState, !hasOurSettings else { return nil }
        return .blocked("It needs ~/.local/bin/dynotch, which is something else.")
    }

    private var hasOurSettings: Bool {
        guard let settings = try? settingsDocument() else { return false }
        return settings["statusLine"]?["command"]?.stringValue == statusLineCommand
            || AgentHook.events.contains { Self.hasCommand(hookCommand, in: settings["hooks"]?[$0.name]) }
    }

    // MARK: Showing what changes

    /// What installing `items` would do, for showing before it's done. What they need comes along.
    func installChanges(for items: Set<SetupItem>) -> [Change] {
        var changes: [Change] = []
        for item in Self.withNeeds(items, in: self) where canInstall(item) {
            switch item {
            case .command:
                changes.append(Change(item: item, summary: "Link it into ~/.local/bin, which needs no password",
                                      text: "\(Self.tilde(linkURL.path, in: home)) → \(commandInApp.path)"))
            case .longCommands:
                let text = read(zshrcURL) ?? ""
                changes.append(Change(item: item, summary: "Add a marked block to ~/.zshrc", text: zshBlock(text: text)))
            case .claudeHooks:
                let waits = AgentHook.events.filter(\.waits).map(\.name).joined(separator: ", ")
                let others = AgentHook.events.filter { !$0.waits }.map(\.name).joined(separator: ", ")
                changes.append(Change(item: item, summary: "Add hooks to ~/.claude/settings.json, beside any you have",
                                      text: "\(waits): \(hookCommand)\n\(others): \(hookCommand), in the background"))
            case .claudeStatusLine:
                changes.append(Change(item: item, summary: "Set the status line in ~/.claude/settings.json",
                                      text: statusLineCommand))
            }
        }
        return changes
    }

    /// What undoing `items` would do.
    func undoChanges(for items: Set<SetupItem>) -> [Change] {
        var changes: [Change] = []
        for item in Self.withDependents(items, in: self) where canUndo(item) {
            switch item {
            case .command:
                changes.append(Change(item: item, summary: "Remove the link", text: Self.tilde(linkURL.path, in: home)))
            case .longCommands:
                let block = read(zshrcURL).flatMap { text in Self.block(in: text).map { String(text[$0]) } } ?? ""
                changes.append(Change(item: item, summary: "Take the block out of ~/.zshrc", text: block))
            case .claudeHooks:
                changes.append(Change(item: item, summary: "Take Dynotch's hooks out of ~/.claude/settings.json",
                                      text: "\(AgentHook.events.map(\.name).joined(separator: ", ")): \(hookCommand)"))
            case .claudeStatusLine:
                changes.append(Change(item: item, summary: "Take the status line out of ~/.claude/settings.json",
                                      text: statusLineCommand))
            }
        }
        return changes
    }

    func canInstall(_ item: SetupItem) -> Bool {
        switch state(of: item) {
        case .notInstalled, .outOfDate: true
        case .installed, .blocked: false
        }
    }

    func canUndo(_ item: SetupItem) -> Bool {
        switch state(of: item) {
        case .installed, .outOfDate: true
        case .notInstalled, .blocked: false
        }
    }

    /// `items` and what they rely on, in the order they go in.
    static func withNeeds(_ items: Set<SetupItem>, in setup: TerminalSetup) -> [SetupItem] {
        var wanted = items
        if items.contains(where: \.needsCommand), setup.canInstall(.command) { wanted.insert(.command) }
        return ordered(wanted)
    }

    /// `items` and what would stop working without them, in the order they go in.
    static func withDependents(_ items: Set<SetupItem>, in setup: TerminalSetup) -> [SetupItem] {
        var wanted = items
        if items.contains(.command) {
            wanted.formUnion(SetupItem.allCases.filter { $0.needsCommand && setup.canUndo($0) })
        }
        return ordered(wanted)
    }

    private static func ordered(_ items: Set<SetupItem>) -> [SetupItem] {
        SetupItem.allCases.filter(items.contains)
    }

    /// A fingerprint of everything shown, so a change made after it was shown isn't overwritten unseen.
    var fingerprint: String {
        [zshrcURL, settingsURL].map { read($0) ?? "" }.joined(separator: "\u{0}")
            + ((try? manager.destinationOfSymbolicLink(atPath: linkURL.path)) ?? "")
    }

    // MARK: Changing things

    /// Installs `items`, as long as nothing has moved since `reviewed`.
    func install(_ items: Set<SetupItem>, reviewed: String) throws {
        guard fingerprint == reviewed else { throw Failure.changedSinceReview }
        for item in Self.withNeeds(items, in: self) where canInstall(item) {
            switch item {
            case .command: try installLink()
            case .longCommands: try installBlock()
            case .claudeHooks: try changeSettings { try addHooks(to: &$0) }
            case .claudeStatusLine: try changeSettings { addStatusLine(to: &$0) }
            }
        }
    }

    /// Takes out what `items` put in, and only that.
    func undo(_ items: Set<SetupItem>, reviewed: String) throws {
        guard fingerprint == reviewed else { throw Failure.changedSinceReview }
        // The hooks go first: they'd fail for as long as they outlived the link.
        for item in Self.withDependents(items, in: self).reversed() where canUndo(item) {
            switch item {
            case .command: try removeLink()
            case .longCommands: try removeBlock()
            case .claudeHooks: try changeSettings { removeHooks(from: &$0) }
            case .claudeStatusLine: try changeSettings { $0["statusLine"] = nil }
            }
        }
    }

    // MARK: The link

    private func installLink() throws {
        do {
            try manager.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if commandState == .outOfDate { try manager.removeItem(at: linkURL) }
            try manager.createSymbolicLink(atPath: linkURL.path, withDestinationPath: commandInApp.path)
        } catch {
            throw Failure.couldNotWrite("~/.local/bin/dynotch")
        }
    }

    private func removeLink() throws {
        do {
            try manager.removeItem(at: linkURL)
        } catch {
            throw Failure.couldNotWrite("~/.local/bin/dynotch")
        }
    }

    /// Dynotch's own command, in this copy of the app or one that's since moved.
    private static func isDynotchCommand(_ path: String) -> Bool {
        path.hasSuffix(".app/Contents/Resources/dynotch")
    }

    // MARK: ~/.zshrc

    /// The block, including its markers.
    private func zshBlock(text: String) -> String {
        var lines = [Self.blockStart, "# Added by Dynotch, in Settings under General. Terminal setup there takes it out again."]
        // Already on the way, from a file a block of this kind can't see past.
        if !Self.reachesLocalBin(text.removingBlock) {
            lines.append("export PATH=\"$HOME/.local/bin:$PATH\"")
        }
        let hook = Self.quoted(longCommandHook.path)
        lines.append("[[ -r \(hook) ]] && source \(hook)")
        lines.append(Self.blockEnd)
        return lines.joined(separator: "\n")
    }

    private static func reachesLocalBin(_ text: String) -> Bool {
        text.split(separator: "\n").contains { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            return !line.hasPrefix("#") && line.contains(".local/bin")
        }
    }

    /// Where the block is, if it's whole: one start, then one end after it.
    private static func block(in text: String) -> Range<String.Index>? {
        guard let start = text.range(of: blockStart), let end = text.range(of: blockEnd), start.lowerBound < end.lowerBound,
              text.ranges(of: blockStart).count == 1, text.ranges(of: blockEnd).count == 1 else { return nil }
        return start.lowerBound..<end.upperBound
    }

    private func installBlock() throws {
        var text = read(zshrcURL) ?? ""
        let block = zshBlock(text: text)
        if let existing = Self.block(in: text) {
            text.replaceSubrange(existing, with: block)
        } else {
            if !text.isEmpty {
                if !text.hasSuffix("\n") { text += "\n" }
                text += "\n"
            }
            text += block + "\n"
        }
        try write(text, to: zshrcURL, newFileMode: 0o644)
    }

    private func removeBlock() throws {
        guard let text = read(zshrcURL), let range = Self.block(in: text) else { return }
        var before = String(text[..<range.lowerBound]), after = String(text[range.upperBound...])
        // The line it ended, and the blank line that was put in front of it.
        if after.hasPrefix("\n") { after.removeFirst() }
        if after.isEmpty, before.hasSuffix("\n\n") { before.removeLast() }
        try write(before + after, to: zshrcURL, newFileMode: 0o644)
    }

    // MARK: ~/.claude/settings.json

    private func settingsDocument() throws -> OrderedJSON {
        guard let text = read(settingsURL), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .object([])
        }
        let document = try OrderedJSON(parsing: text)
        guard case .object = document else { throw OrderedJSON.Failure.malformed }
        return document
    }

    private func changeSettings(_ change: (inout OrderedJSON) throws -> Void) throws {
        guard var document = try? settingsDocument() else { throw Failure.blocked("~/.claude/settings.json isn't valid JSON.") }
        try change(&document)
        try write(document.printed() + "\n", to: settingsURL, newFileMode: 0o600)
    }

    private func addHooks(to settings: inout OrderedJSON) throws {
        var hooks = settings["hooks"] ?? .object([])
        guard case .object = hooks else { throw Failure.blocked("The hooks in ~/.claude/settings.json aren't what they should be.") }
        for event in AgentHook.events where !Self.hasCommand(hookCommand, in: hooks[event.name]) {
            guard case .array(var groups) = hooks[event.name] ?? .array([]) else {
                throw Failure.blocked("The hooks in ~/.claude/settings.json aren't what they should be.")
            }
            groups.append(hookGroup(waits: event.waits))
            hooks[event.name] = .array(groups)
        }
        settings["hooks"] = hooks
    }

    private func hookGroup(waits: Bool) -> OrderedJSON {
        var handler = OrderedJSON.object([.init(key: "type", value: .text("command")), .init(key: "command", value: .text(hookCommand))])
        if waits {
            handler["timeout"] = .literal("600")
        } else {
            // Nothing in Claude Code waits for these.
            handler["async"] = .literal("true")
        }
        return .object([.init(key: "hooks", value: .array([handler]))])
    }

    private func removeHooks(from settings: inout OrderedJSON) {
        guard var hooks = settings["hooks"] else { return }
        for event in AgentHook.events {
            guard case .array(let groups) = hooks[event.name] else { continue }
            let kept = groups.compactMap { group -> OrderedJSON? in
                guard case .array(let handlers) = group["hooks"], Self.hasCommand(hookCommand, in: .array([group])) else { return group }
                let others = handlers.filter { $0["command"]?.stringValue != hookCommand }
                guard !others.isEmpty else { return nil }
                var group = group
                group["hooks"] = .array(others)
                return group
            }
            hooks[event.name] = kept.isEmpty ? nil : .array(kept)
        }
        settings["hooks"] = hooks == .object([]) ? nil : hooks
    }

    private func addStatusLine(to settings: inout OrderedJSON) {
        settings["statusLine"] = .object([.init(key: "type", value: .text("command")),
                                          .init(key: "command", value: .text(statusLineCommand))])
    }

    /// Whether any group under an event runs `command`.
    private static func hasCommand(_ command: String, in groups: OrderedJSON?) -> Bool {
        guard case .array(let groups) = groups else { return false }
        return groups.contains { group in
            guard case .array(let handlers) = group["hooks"] else { return false }
            return handlers.contains { $0["command"]?.stringValue == command }
        }
    }

    // MARK: Files

    private func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    /// Replaces a file in one step, keeping its permissions and going through a link rather than
    /// over it, so a dotfile kept elsewhere stays there. What was there goes to the backups first.
    private func write(_ text: String, to url: URL, newFileMode: mode_t) throws {
        let target = url.resolvingSymlinksInPath()
        let name = Self.tilde(url.path, in: home)
        do {
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            var mode = newFileMode
            var info = stat()
            if stat(target.path, &info) == 0 {
                mode = info.st_mode & 0o777
                try backUp(target)
            }
            let scratch = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).dynotch-\(UUID().uuidString)")
            defer { try? manager.removeItem(at: scratch) }
            try Data(text.utf8).write(to: scratch)
            guard chmod(scratch.path, mode) == 0, rename(scratch.path, target.path) == 0 else {
                throw Failure.couldNotWrite(name)
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.couldNotWrite(name)
        }
    }

    /// Keeps the last few copies of each file, which only this user can read.
    private func backUp(_ file: URL) throws {
        try manager.createDirectory(at: backupsURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stamp = Int(Date.now.timeIntervalSince1970)
        var name = "\(file.lastPathComponent)-\(stamp)"
        var number = 1
        while exists(backupsURL.appendingPathComponent(name)) {
            number += 1
            name = "\(file.lastPathComponent)-\(stamp)-\(number)"
        }
        let copy = backupsURL.appendingPathComponent(name)
        try manager.copyItem(at: file, to: copy)
        _ = chmod(copy.path, 0o600)
        let copies = (try? manager.contentsOfDirectory(atPath: backupsURL.path)) ?? []
        let old = copies.filter { $0.hasPrefix("\(file.lastPathComponent)-") }
            .sorted { Self.stamp($0) < Self.stamp($1) }.dropLast(Self.backupsKept)
        for name in old { try? manager.removeItem(at: backupsURL.appendingPathComponent(name)) }
    }

    private static let backupsKept = 5

    /// When a backup was made, and which it was within that second.
    private static func stamp(_ name: String) -> (Int, Int) {
        let parts = name.split(separator: "-").compactMap { Int($0) }
        return (parts.first ?? 0, parts.dropFirst().first ?? 1)
    }

    /// A path as it's safe to put in a shell command: bare when it can be, in single quotes when not.
    static func quoted(_ path: String) -> String {
        if path.range(of: #"^[A-Za-z0-9_./+-]+$"#, options: .regularExpression) != nil { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func tilde(_ path: String, in home: URL) -> String {
        path.hasPrefix(home.path + "/") ? "~" + path.dropFirst(home.path.count) : path
    }
}

private extension String {
    /// This text with any Dynotch block taken out.
    var removingBlock: String {
        guard let start = range(of: TerminalSetup.blockStart), let end = range(of: TerminalSetup.blockEnd),
              start.lowerBound < end.lowerBound else { return self }
        return String(self[..<start.lowerBound]) + String(self[end.upperBound...])
    }

    func ranges(of text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var from = startIndex
        while let range = range(of: text, range: from..<endIndex) {
            found.append(range)
            from = range.upperBound
        }
        return found
    }
}
