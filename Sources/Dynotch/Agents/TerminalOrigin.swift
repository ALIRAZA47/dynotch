import AppKit

/// Where a command or a session ran, so a click can go back to it. All of this comes from the
/// process that sent it, so it's only ever used to pick out a terminal to bring forward.
struct TerminalOrigin: Equatable, Sendable {
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
        self.init(program: environment["TERM_PROGRAM"], bundleID: environment["__CFBundleIdentifier"],
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

    /// What the button says.
    var title: String { "Back" }

    /// Brings the terminal forward, on the right tab where it allows that.
    @MainActor
    func focus() {}
}
