import Foundation

/// Where a command or a session ran, so a click can go back to it. All of this comes from the
/// process that sent it, so it's only ever used to pick out a terminal to bring forward.
package struct TerminalOrigin: Equatable, Sendable {
    /// What stands in for `$TERM_PROGRAM` inside tmux, whatever version of tmux it is.
    package static let tmux = "tmux"

    /// `$TERM_PROGRAM`, such as `iTerm.app`, `Apple_Terminal` or `ghostty`.
    package var program: String?
    /// `$__CFBundleIdentifier`, the app that started the shell, where macOS set one.
    package var bundleID: String?
    /// The terminal's own name for the tab, such as `$ITERM_SESSION_ID`.
    package var sessionID: String?
    /// `$TTY`.
    package var tty: String?
    /// The working folder.
    package var folder: String?

    package init(program: String? = nil, bundleID: String? = nil, sessionID: String? = nil, tty: String? = nil, folder: String? = nil) {
        self.program = program
        self.bundleID = bundleID
        self.sessionID = sessionID
        self.tty = tty
        self.folder = folder
    }

    /// As the process reporting it sees things.
    package init(environment: [String: String], folder: String? = nil) {
        let inTmux = environment["TMUX"].map { !$0.isEmpty } ?? false
        self.init(program: inTmux ? Self.tmux : environment["TERM_PROGRAM"], bundleID: environment["__CFBundleIdentifier"],
                  sessionID: environment["ITERM_SESSION_ID"] ?? environment["TERM_SESSION_ID"],
                  tty: environment["TTY"], folder: folder ?? environment["PWD"])
    }

    /// How it travels over the socket.
    package var fields: [String: String] {
        var fields: [String: String] = [:]
        fields["program"] = program
        fields["bundleID"] = bundleID
        fields["sessionID"] = sessionID
        fields["tty"] = tty
        fields["folder"] = folder
        return fields
    }

    package init(fields: [String: Any]) {
        self.init(program: fields["program"] as? String, bundleID: fields["bundleID"] as? String,
                  sessionID: fields["sessionID"] as? String, tty: fields["tty"] as? String,
                  folder: fields["folder"] as? String)
    }

    /// Inside tmux the app can come forward, but no tab can be picked.
    package var isInTmux: Bool { program == Self.tmux }
}
