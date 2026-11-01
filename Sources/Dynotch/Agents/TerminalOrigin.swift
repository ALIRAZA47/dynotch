import AppKit

/// Where a command or a session ran, so a click can go back to it. All of this comes from the
/// process that sent it, so it's only ever used to pick out a terminal to bring forward.
struct TerminalOrigin: Equatable, Sendable {
    /// What stands in for `$TERM_PROGRAM` inside tmux, whatever version of tmux it is.
    static let tmux = "tmux"
    /// What a notice's button holds.
    private static let longestTitle = 16

    /// `$TERM_PROGRAM`, such as `iTerm.app`, `Apple_Terminal` or `ghostty`.
    var program: String?
    /// `$__CFBundleIdentifier`, the app that started the shell, where macOS set one.
    var bundleID: String?
    /// The terminal's own name for the tab, such as `$ITERM_SESSION_ID`.
    var sessionID: String?
    /// `$TTY`.
    var tty: String?
    /// The working folder.
    var folder: String?

    init(program: String? = nil, bundleID: String? = nil, sessionID: String? = nil, tty: String? = nil, folder: String? = nil) {
        self.program = program
        self.bundleID = bundleID
        self.sessionID = sessionID
        self.tty = tty
        self.folder = folder
    }

    /// As the process reporting it sees things.
    init(environment: [String: String], folder: String? = nil) {
        let inTmux = environment["TMUX"].map { !$0.isEmpty } ?? false
        self.init(program: inTmux ? Self.tmux : environment["TERM_PROGRAM"], bundleID: environment["__CFBundleIdentifier"],
                  sessionID: environment["ITERM_SESSION_ID"] ?? environment["TERM_SESSION_ID"],
                  tty: environment["TTY"], folder: folder ?? environment["PWD"])
    }

    /// How it travels over the socket.
    var fields: [String: String] {
        var fields: [String: String] = [:]
        fields["program"] = program
        fields["bundleID"] = bundleID
        fields["sessionID"] = sessionID
        fields["tty"] = tty
        fields["folder"] = folder
        return fields
    }

    init(fields: [String: Any]) {
        self.init(program: fields["program"] as? String, bundleID: fields["bundleID"] as? String,
                  sessionID: fields["sessionID"] as? String, tty: fields["tty"] as? String,
                  folder: fields["folder"] as? String)
    }

    /// Inside tmux the app can come forward, but no tab can be picked.
    var isInTmux: Bool { program == Self.tmux }

    /// The app to go back to, from the list and nowhere else. Where both names are given both have
    /// to check out: a program Dynotch knows from an app it doesn't is likely a fork of it, and
    /// bringing up the original would be wrong. The bundle ID then picks between the apps that set
    /// that program. If the app doesn't set it the program stands, since a terminal sets its program
    /// itself, while anything started from a shell inherits that shell's bundle ID.
    var terminal: KnownTerminal? {
        let program = isInTmux ? nil : program.flatMap { $0.isEmpty ? nil : $0 }
        let bundleID = bundleID.flatMap { $0.isEmpty ? nil : $0 }
        let named = program.flatMap(KnownTerminal.with(program:))
        guard let bundleID else { return named }
        guard let app = KnownTerminal.with(bundleID: bundleID) else { return nil }
        if let program, !app.sets(program: program) { return named }
        return app
    }

    /// How to find its tab, or nil where the app can only come forward: most terminals have no way
    /// to ask, and a value that doesn't look right is treated as if it wasn't there.
    var script: TerminalScript? {
        guard !isInTmux else { return nil }
        switch terminal?.bundleID {
        case "com.googlecode.iterm2": return TerminalScript.iTerm(sessionID: sessionID)
        case "com.apple.Terminal": return TerminalScript.terminal(tty: tty)
        case "com.mitchellh.ghostty": return TerminalScript.ghostty(tty: tty, folder: folder)
        default: return nil
        }
    }

    /// What the button says: where it goes, if that fits.
    var title: String {
        guard let name = terminal?.name else { return "Back" }
        let title = "Back to \(name)"
        return title.count <= Self.longestTitle ? title : "Back"
    }

    /// The button back to it, or nil if it's nowhere Dynotch would go.
    var action: NoticeAction? {
        terminal == nil ? nil : NoticeAction(title: title, kind: .focusTerminal(self))
    }

    /// Brings the terminal forward, on the right tab where it allows that.
    @MainActor
    func focus() {
        focus(on: .live)
    }

    /// The app comes first, and whatever becomes of the script after that, it's already there: a
    /// refused prompt, a terminal that has hung or a tab that has closed all end up the same way.
    /// A terminal that has been quit gets no script, which would only start it to ask.
    @MainActor @discardableResult
    func focus(on mac: TerminalMac) -> Task<Void, Never>? {
        guard let terminal else { return nil }
        let wasRunning = mac.isRunning(terminal.bundleID)
        mac.bringForward(terminal.bundleID)
        guard wasRunning, let script else { return nil }
        let run = mac.run
        return Task { await run(script) }
    }
}

/// The part of going back that touches the Mac, apart so that no test has to bring anything forward.
struct TerminalMac {
    var isRunning: @MainActor (_ bundleID: String) -> Bool
    var bringForward: @MainActor (_ bundleID: String) -> Void
    /// Off the main thread: macOS's Automation prompt holds up the first script until it's answered.
    var run: @Sendable (TerminalScript) async -> Void

    private static let runner = AppleScriptRunner()

    static let live = TerminalMac(
        isRunning: { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty },
        bringForward: { bundleID in
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        },
        run: { script in
            _ = await runner.run(script.source, handler: TerminalScript.handler, arguments: script.arguments)
        }
    )
}

/// A terminal Dynotch can go back to. Anything on the Mac can send a link naming any app it likes,
/// so this list is the only way an app gets brought forward, and a name that isn't on it gets no button.
struct KnownTerminal: Equatable, Sendable {
    /// What the button calls it.
    let name: String
    let bundleID: String
    /// What it sets `$TERM_PROGRAM` to. Several apps can set the same one, as editors built from
    /// VS Code do. On its own it means the first of them on the list.
    var programs: [String] = []

    static let all = [
        KnownTerminal(name: "Terminal", bundleID: "com.apple.Terminal", programs: ["Apple_Terminal"]),
        KnownTerminal(name: "iTerm", bundleID: "com.googlecode.iterm2", programs: ["iTerm.app"]),
        KnownTerminal(name: "Ghostty", bundleID: "com.mitchellh.ghostty", programs: ["ghostty"]),
        KnownTerminal(name: "WezTerm", bundleID: "com.github.wez.wezterm", programs: ["WezTerm"]),
        KnownTerminal(name: "Warp", bundleID: "dev.warp.Warp-Stable", programs: ["WarpTerminal"]),
        KnownTerminal(name: "Warp", bundleID: "dev.warp.Warp-Preview", programs: ["WarpTerminal"]),
        KnownTerminal(name: "Alacritty", bundleID: "org.alacritty", programs: ["alacritty"]),
        KnownTerminal(name: "kitty", bundleID: "net.kovidgoyal.kitty", programs: ["kitty"]),
        KnownTerminal(name: "Hyper", bundleID: "co.zeit.hyper", programs: ["Hyper"]),
        KnownTerminal(name: "Tabby", bundleID: "org.tabby", programs: ["Tabby"]),
        KnownTerminal(name: "Rio", bundleID: "com.raphaelamorim.rio", programs: ["rio"]),
        KnownTerminal(name: "VS Code", bundleID: "com.microsoft.VSCode", programs: ["vscode"]),
        KnownTerminal(name: "VS Code", bundleID: "com.microsoft.VSCodeInsiders", programs: ["vscode"]),
        KnownTerminal(name: "VSCodium", bundleID: "com.vscodium", programs: ["vscode"]),
        KnownTerminal(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92", programs: ["vscode"]),
        KnownTerminal(name: "Zed", bundleID: "dev.zed.Zed", programs: ["zed"]),
        KnownTerminal(name: "Zed", bundleID: "dev.zed.Zed-Preview", programs: ["zed"]),
        KnownTerminal(name: "Zed", bundleID: "dev.zed.Zed-Nightly", programs: ["zed"]),
        KnownTerminal(name: "Claude", bundleID: "com.anthropic.claudefordesktop"),
        KnownTerminal(name: "IntelliJ", bundleID: "com.jetbrains.intellij"),
        KnownTerminal(name: "IntelliJ", bundleID: "com.jetbrains.intellij.ce"),
        KnownTerminal(name: "WebStorm", bundleID: "com.jetbrains.WebStorm"),
        KnownTerminal(name: "PyCharm", bundleID: "com.jetbrains.pycharm"),
        KnownTerminal(name: "PyCharm", bundleID: "com.jetbrains.pycharm.ce"),
        KnownTerminal(name: "GoLand", bundleID: "com.jetbrains.goland"),
        KnownTerminal(name: "DataGrip", bundleID: "com.jetbrains.datagrip"),
    ]

    static func with(bundleID: String) -> KnownTerminal? {
        all.first { $0.bundleID == bundleID }
    }

    static func with(program: String) -> KnownTerminal? {
        all.first { $0.sets(program: program) }
    }

    /// Whatever its case, which can only ever match an app on the list.
    func sets(program: String) -> Bool {
        programs.contains { $0.caseInsensitiveCompare(program) == .orderedSame }
    }
}
