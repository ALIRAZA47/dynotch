import Foundation

/// JSON that keeps its keys in order and its numbers and strings exactly as written. `JSONSerialization`
/// loses both, and a settings file of someone else's should come back as it went in, apart from the
/// change. A file `JSON.stringify(_, null, 2)` wrote, as Claude Code's is, comes back byte for byte.
indirect enum OrderedJSON: Equatable {
    struct Member: Equatable {
        var key: String
        var value: OrderedJSON
    }

    case object([Member])
    case array([OrderedJSON])
    /// As written, escapes and all, without its quotes.
    case string(raw: String)
    /// A number, `true`, `false` or `null`, as written.
    case literal(String)

    enum Failure: Error, Equatable {
        case malformed
    }

    /// A string, escaped for JSON.
    static func text(_ value: String) -> OrderedJSON {
        var raw = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": raw += "\\\""
            case "\\": raw += "\\\\"
            case "\n": raw += "\\n"
            case "\r": raw += "\\r"
            case "\t": raw += "\\t"
            case _ where scalar.value < 0x20: raw += String(format: "\\u%04x", scalar.value)
            default: raw.unicodeScalars.append(scalar)
            }
        }
        return .string(raw: raw)
    }

    // MARK: Reading

    init(parsing text: String) throws {
        var parser = Parser(bytes: Array(text.utf8))
        self = try parser.value(depth: 0)
        parser.skipSpace()
        guard parser.isAtEnd else { throw Failure.malformed }
    }

    /// What a string says, with its escapes worked out.
    var stringValue: String? {
        guard case .string(let raw) = self else { return nil }
        return try? JSONDecoder().decode(String.self, from: Data("\"\(raw)\"".utf8))
    }

    subscript(key: String) -> OrderedJSON? {
        get {
            guard case .object(let members) = self else { return nil }
            return members.first { $0.key == key }?.value
        }
        set {
            guard case .object(var members) = self else { return }
            if let index = members.firstIndex(where: { $0.key == key }) {
                if let newValue {
                    members[index].value = newValue
                } else {
                    members.remove(at: index)
                }
            } else if let newValue {
                members.append(Member(key: key, value: newValue))
            }
            self = .object(members)
        }
    }

    // MARK: Writing

    /// As `JSON.stringify(_, null, 2)` writes it.
    func printed(indent: Int = 0) -> String {
        let inner = String(repeating: "  ", count: indent + 1), outer = String(repeating: "  ", count: indent)
        switch self {
        case .object(let members):
            guard !members.isEmpty else { return "{}" }
            let lines = members.map { "\(inner)\"\($0.key)\": \($0.value.printed(indent: indent + 1))" }
            return "{\n" + lines.joined(separator: ",\n") + "\n\(outer)}"
        case .array(let items):
            guard !items.isEmpty else { return "[]" }
            let lines = items.map { inner + $0.printed(indent: indent + 1) }
            return "[\n" + lines.joined(separator: ",\n") + "\n\(outer)]"
        case .string(let raw):
            return "\"\(raw)\""
        case .literal(let value):
            return value
        }
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        var isAtEnd: Bool { index >= bytes.count }

        private static let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\")

        mutating func skipSpace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        private mutating func expect(_ character: Character) -> Bool {
            skipSpace()
            guard index < bytes.count, bytes[index] == character.asciiValue else { return false }
            index += 1
            return true
        }

        mutating func value(depth: Int) throws -> OrderedJSON {
            guard depth < 64 else { throw Failure.malformed }
            skipSpace()
            guard index < bytes.count else { throw Failure.malformed }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try object(depth: depth)
            case UInt8(ascii: "["): return try array(depth: depth)
            case Self.quote: return .string(raw: try string())
            default: return .literal(try literal())
            }
        }

        private mutating func object(depth: Int) throws -> OrderedJSON {
            index += 1
            var members: [Member] = []
            if expect("}") { return .object(members) }
            repeat {
                skipSpace()
                guard index < bytes.count, bytes[index] == Self.quote else { throw Failure.malformed }
                let key = try string()
                guard expect(":") else { throw Failure.malformed }
                members.append(Member(key: key, value: try value(depth: depth + 1)))
            } while expect(",")
            guard expect("}") else { throw Failure.malformed }
            return .object(members)
        }

        private mutating func array(depth: Int) throws -> OrderedJSON {
            index += 1
            var items: [OrderedJSON] = []
            if expect("]") { return .array(items) }
            repeat {
                items.append(try value(depth: depth + 1))
            } while expect(",")
            guard expect("]") else { throw Failure.malformed }
            return .array(items)
        }

        /// A string's text, as written. Reading it leaves `index` past its closing quote.
        private mutating func string() throws -> String {
            index += 1
            let start = index
            while index < bytes.count {
                switch bytes[index] {
                case Self.quote:
                    defer { index += 1 }
                    return String(decoding: bytes[start..<index], as: UTF8.self)
                case Self.backslash:
                    index += 2
                case 0..<0x20:
                    throw Failure.malformed
                default:
                    index += 1
                }
            }
            throw Failure.malformed
        }

        private mutating func literal() throws -> String {
            let start = index
            while index < bytes.count, !" \t\r\n,]}".utf8.contains(bytes[index]) { index += 1 }
            let word = String(decoding: bytes[start..<index], as: UTF8.self)
            // A number as JSON allows it, or one of the three words.
            guard ["true", "false", "null"].contains(word)
                    || word.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil else {
                throw Failure.malformed
            }
            return word
        }
    }
}
