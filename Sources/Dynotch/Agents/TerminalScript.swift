import Foundation

/// A script that picks out one tab, and what it's looking for. The source never changes: whatever
/// came from a link or the socket goes in as arguments, so it stays text and can't become code.
/// None of these scripts do anything but select a tab, and `do shell script` has no place in them.
struct TerminalScript: Equatable, Sendable {
    /// The one handler in each script.
    static let handler = "pick"

    let source: String
    let arguments: [String]

    // MARK: Each terminal

    /// iTerm2 names each session, so this one is exact.
    static func iTerm(sessionID: String?) -> TerminalScript? {
        uuid(inSessionID: sessionID).map { TerminalScript(source: iTermSource, arguments: [$0]) }
    }

    /// Terminal.app has no session ids it will answer to, but each tab knows its tty.
    static func terminal(tty: String?) -> TerminalScript? {
        checked(tty: tty).map { TerminalScript(source: terminalSource, arguments: [$0]) }
    }

    /// Ghostty's terminals know their tty from 1.4. Before that they only know their folder, and two
    /// tabs in one folder could be either, so then it picks neither. Empty text stands for a value
    /// that's missing, and the source says what it does on a Ghostty that has no `tty` to ask for.
    static func ghostty(tty: String?, folder: String?) -> TerminalScript? {
        let tty = checked(tty: tty), folder = checked(folder: folder)
        guard tty != nil || folder != nil else { return nil }
        return TerminalScript(source: ghosttySource, arguments: [tty ?? "", folder ?? ""])
    }

    // MARK: What a value has to look like

    /// `/dev/ttys003`, and nothing else.
    static func checked(tty: String?) -> String? {
        tty.flatMap { matches($0, #"^/dev/ttys[0-9]+$"#) ? $0 : nil }
    }

    /// The UUID out of an iTerm session id such as `w0t1p0:7E0D7E04-8FD6-4E87-A1F0-5B61A7A6AB7B`.
    static func uuid(inSessionID sessionID: String?) -> String? {
        let hex = "[0-9A-Fa-f]"
        let shape = "^w[0-9]+t[0-9]+p[0-9]+:\(hex){8}-\(hex){4}-\(hex){4}-\(hex){4}-\(hex){12}$"
        return sessionID.flatMap { matches($0, shape) ? String($0.suffix(36)) : nil }
    }

    /// An absolute path on one line, with neither of the characters that could end a quoted string.
    static func checked(folder: String?) -> String? {
        guard let folder, folder.hasPrefix("/"), folder.utf8.count <= Int(PATH_MAX) else { return nil }
        let isSafe = folder.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) && $0 != "\"" && $0 != "\\"
        }
        return isSafe ? folder : nil
    }

    /// The whole of `text` has to fit `pattern`. A regex's `$` can also match before a last newline,
    /// and whether this search lets it depends on the Foundation underneath, so that's not left to it.
    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) == text.startIndex..<text.endIndex
    }

    // MARK: The scripts

    private static let iTermSource = """
        on pick(wanted)
            tell application id "com.googlecode.iterm2"
                repeat with aWindow in windows
                    repeat with aTab in tabs of aWindow
                        repeat with aSession in sessions of aTab
                            if unique ID of aSession is wanted then
                                select aWindow
                                select aTab
                                select aSession
                                activate
                                return true
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return false
        end pick
        """

    private static let terminalSource = """
        on pick(wanted)
            tell application id "com.apple.Terminal"
                repeat with aWindow in windows
                    repeat with aTab in tabs of aWindow
                        if tty of aTab is wanted then
                            set miniaturized of aWindow to false
                            set selected tab of aWindow to aTab
                            set frontmost of aWindow to true
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end tell
            return false
        end pick
        """

    private static let ghosttySource = """
        on pick(wantedTTY, wantedFolder)
            tell application id "com.mitchellh.ghostty"
                set found to {}
                if wantedTTY is not "" then
                    -- Before 1.4 this fails, and leaves only the folder to go on.
                    try
                        set found to terminals whose tty is wantedTTY
                    end try
                end if
                if (count of found) is 0 and wantedFolder is not "" then
                    set found to terminals whose working directory is wantedFolder
                end if
                if (count of found) is 1 then
                    focus item 1 of found
                    activate
                    return true
                end if
            end tell
            return false
        end pick
        """
}
