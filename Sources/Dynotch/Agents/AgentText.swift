import Foundation

/// Text from a session, made to say what it is. Control characters, terminal escapes, bidirectional
/// overrides and characters that draw nothing come out as visible markers instead of doing what they
/// do, so a command can't hide its tail or read backwards. So do marks stacked past what any writing
/// needs, which can paint over the lines around them.
enum HonestText {
    struct Run: Equatable {
        enum Kind: Equatable {
            case text
            /// Something that would otherwise be interpreted or go unseen.
            case marker
            /// A tab: marked like the rest, but it's in a lot of source code, so it stays quiet.
            case tab
        }

        var text: String
        var kind: Kind
    }

    /// The names of the first 32 characters of ASCII.
    private static let controlNames = ["NUL", "SOH", "STX", "ETX", "EOT", "ENQ", "ACK", "BEL", "BS", "HT", "LF", "VT", "FF",
                                       "CR", "SO", "SI", "DLE", "DC1", "DC2", "DC3", "DC4", "NAK", "SYN", "ETB", "CAN", "EM",
                                       "SUB", "ESC", "FS", "GS", "RS", "US"]

    /// How many marks can sit on one letter. Accents and vowel signs don't need more.
    private static let mostMarks = 2

    /// `text` as it's shown. It's taken as one line: split it first to keep its line breaks.
    static func runs(_ text: String) -> [Run] {
        var runs: [Run] = []
        var plain = String.UnicodeScalarView()
        var marks = 0
        for scalar in text.unicodeScalars {
            marks = scalar.properties.generalCategory == .nonspacingMark ? marks + 1 : 0
            if let marker = marker(for: scalar) ?? (marks > mostMarks ? numbered(scalar) : nil) {
                if !plain.isEmpty { runs.append(Run(text: String(plain), kind: .text)) }
                plain = String.UnicodeScalarView()
                runs.append(Run(text: marker, kind: scalar == "\t" ? .tab : .marker))
            } else {
                plain.append(scalar)
            }
        }
        if !plain.isEmpty { runs.append(Run(text: String(plain), kind: .text)) }
        return runs
    }

    /// A name for one line of the notch: nothing past `limit`, and nil if nothing's left.
    static func line(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let shown = runs(text).map(\.text).joined().trimmingCharacters(in: .whitespaces)
        return shown.isEmpty ? nil : String(shown.prefix(limit))
    }

    /// `text` split at its line breaks and nowhere else. A `\r\n` is one `Character`, so it's split by scalars.
    static func lines(of text: String) -> [String] {
        text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
    }

    /// `text`, with a left-to-right mark after each run of right-to-left letters. Without one, two such
    /// words and whatever's between them read as one run, so `mv אאא בבב` would show its arguments swapped.
    static func keepingOrder(_ text: String) -> String {
        guard !text.utf8.allSatisfy({ $0 < 0x80 }) else { return text }
        var kept = String.UnicodeScalarView()
        var isRightToLeft = false
        for scalar in text.unicodeScalars {
            let rightToLeft = isWrittenRightToLeft(scalar)
            if isRightToLeft, !rightToLeft, scalar.properties.generalCategory != .nonspacingMark { kept.append("\u{200E}") }
            kept.append(scalar)
            isRightToLeft = rightToLeft || (isRightToLeft && scalar.properties.generalCategory == .nonspacingMark)
        }
        if isRightToLeft { kept.append("\u{200E}") }
        return String(kept)
    }

    /// Hebrew, Arabic and the other right-to-left scripts, by their blocks in Unicode.
    private static func isWrittenRightToLeft(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF: true
        default: false
        }
    }

    private static func numbered(_ scalar: Unicode.Scalar) -> String {
        "<U+\(String(format: "%04X", scalar.value))>"
    }

    /// What shows in place of `scalar`, or nil if it can show as itself.
    static func marker(for scalar: Unicode.Scalar) -> String? {
        switch scalar.value {
        case 0x20...0x7E: return nil
        case 0x09: return "→   "
        case 0..<0x20: return "<\(controlNames[Int(scalar.value)])>"
        case 0x7F: return "<DEL>"
        // A blank pattern of braille dots, and the stand-in for an object: both draw nothing.
        case 0x2800, 0xFFFC: return numbered(scalar)
        default: break
        }
        let properties = scalar.properties
        switch properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator, .spaceSeparator,
             .enclosingMark:
            break
        default:
            guard properties.isBidiControl || properties.isDefaultIgnorableCodePoint || properties.isNoncharacterCodePoint else {
                return nil
            }
        }
        return numbered(scalar)
    }
}

/// What a row or a notice may say about a command: its name, and a subcommand where it has one, such
/// as `swift build`. Never the rest, because arguments can hold tokens and the notch is on screen
/// when you share it. Only the approval's glance shows a whole command.
enum CommandName {
    static let fallback = "command"

    /// As in `notify-long-commands.zsh`, these run the command that follows them.
    private static let wrappers: Set = ["sudo", "doas", "env", "time", "nohup", "nice", "caffeinate", "command", "exec",
                                        "builtin", "noglob", "timeout", "gtimeout"]
    /// Set-up that says nothing about what's going on, so the next command in a chain is the one to name.
    private static let setUp: Set = ["cd", "pushd", "popd", "export", "unset", "set", "source", "true", "ulimit", "umask", "trap", "alias"]
    /// The ones whose first argument is a subcommand. A word after any other command could be anything.
    private static let withSubcommands: Set = [
        "git", "gh", "swift", "xcodebuild", "npm", "pnpm", "yarn", "bun", "npx", "bunx", "uv", "cargo", "go", "docker", "kubectl",
        "make", "gradle", "pip", "pip3", "brew", "dotnet", "terraform", "helm",
    ]
    private static let scriptRunners: Set = ["npm", "pnpm", "yarn", "bun", "uv"]
    private static let longestName = 32
    private static let longestWord = 24
    /// Plenty to find the first command, and no more on every event for a heredoc of megabytes.
    private static let longestLook = 4096

    static func of(_ command: String) -> String {
        let names = segments(of: String(command.prefix(longestLook))).compactMap(name(of:))
        return names.first { !setUp.contains($0) } ?? names.first ?? fallback
    }

    private static func name(of words: [String]) -> String? {
        var words = words[...]
        while let word = words.first, word.contains("=") || word.hasPrefix("-") || wrappers.contains(word) || word.allSatisfy(\.isNumber) {
            words.removeFirst()
        }
        guard let word = words.popFirst() else { return nil }
        let name = (word as NSString).lastPathComponent
        guard name.count <= longestName, name.contains(where: \.isLetter),
              name.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._+-".unicodeScalars.contains($0)) }) else {
            return nil
        }
        guard withSubcommands.contains(name), let subcommand = words.popFirst(), isPlain(subcommand) else { return name }
        if scriptRunners.contains(name), subcommand == "run", let script = words.first, isPlain(script) {
            return "\(name) run \(script)"
        }
        return "\(name) \(subcommand)"
    }

    /// A word that can only be a subcommand: `build`, `run`, `db:migrate`. Nothing a value tends to look like.
    private static func isPlain(_ word: String) -> Bool {
        guard word.count <= longestWord, let first = word.unicodeScalars.first, CharacterSet.lowercaseLetters.contains(first) else { return false }
        return word.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.lowercaseLetters.contains($0) || CharacterSet.decimalDigits.contains($0) || "-_:".unicodeScalars.contains($0))
        }
    }

    /// The words of each command in a line of shell, as far as a name needs: quotes hold, `;`, `&`,
    /// `|` and new lines end a command, and a redirection ends what's worth reading of one.
    private static func segments(of command: String) -> [[String]] {
        var segments: [[String]] = []
        var words: [String] = []
        var word = ""
        var hasWord = false
        var quote: Character?
        var isEscaped = false
        var isRedirected = false
        var isComment = false

        func endWord() {
            if hasWord, !isRedirected { words.append(word) }
            word = ""
            hasWord = false
        }
        func endSegment() {
            endWord()
            if !words.isEmpty { segments.append(words) }
            words = []
            isRedirected = false
        }

        for character in command {
            if isComment {
                if character.isNewline {
                    isComment = false
                    endSegment()
                }
            } else if isEscaped {
                // A backslash at the end of a line only carries the command on to the next.
                if !character.isNewline {
                    word.append(character)
                    hasWord = true
                }
                isEscaped = false
            } else if let open = quote {
                if character == open {
                    quote = nil
                } else if character == "\\", open == "\"" {
                    isEscaped = true
                } else {
                    word.append(character)
                }
            } else {
                switch character {
                case "\\": isEscaped = true
                case "'", "\"":
                    quote = character
                    hasWord = true
                case "#" where !hasWord: isComment = true
                case ";", "&", "|", "(", ")": endSegment()
                case "<", ">":
                    endWord()
                    isRedirected = true
                default:
                    if character.isNewline {
                        endSegment()
                    } else if character.isWhitespace {
                        endWord()
                    } else {
                        word.append(character)
                        hasWord = true
                    }
                }
            }
        }
        // A quote that never closes makes what it holds anyone's guess.
        if quote != nil { hasWord = false }
        endSegment()
        return segments
    }
}

/// How a session's row says what a tool is doing, or wants to do. It takes what names the target,
/// and what it says stays within what `CommandName` allows.
enum AgentWords {
    private static let longestName = 60

    static func doing(tool: String, target: [String: String]) -> String {
        switch tool {
        case "Bash": "Running \(CommandName.of(target["command"] ?? ""))"
        case "Write": "Writing \(file(in: target))"
        case "Edit", "MultiEdit", "NotebookEdit": "Editing \(file(in: target))"
        case "Read": "Reading \(file(in: target))"
        case "Grep", "Glob": "Searching the code"
        case "WebFetch": "Fetching a page"
        case "WebSearch": "Searching the web"
        case "Task", "Agent": "Running a subagent"
        default: "Using \(name(ofTool: tool))"
        }
    }

    static func wants(tool: String, target: [String: String]) -> String {
        switch tool {
        case "Bash": "Wants to run: \(CommandName.of(target["command"] ?? ""))"
        case "Write": "Wants to write: \(file(in: target))"
        case "Edit", "MultiEdit", "NotebookEdit": "Wants to edit: \(file(in: target))"
        case "Read": "Wants to read: \(file(in: target))"
        case "Grep", "Glob": "Wants to search the code"
        case "WebFetch": "Wants to fetch a page"
        case "WebSearch": "Wants to search the web"
        case "Task", "Agent": "Wants to start a subagent"
        default: "Wants to use: \(name(ofTool: tool))"
        }
    }

    /// The server's name for an MCP tool, `github` for `mcp__github__create_issue`, and otherwise the tool's own.
    static func name(ofTool tool: String) -> String {
        let parts = tool.components(separatedBy: "__")
        let name = parts.count > 2 && parts[0] == "mcp" ? parts[1] : tool
        return HonestText.line(name, limit: longestName) ?? "a tool"
    }

    /// The file's own name, not the folders above it.
    private static func file(in target: [String: String]) -> String {
        let path = target["file_path"] ?? target["notebook_path"] ?? ""
        return HonestText.line((path as NSString).lastPathComponent, limit: longestName) ?? "a file"
    }
}
