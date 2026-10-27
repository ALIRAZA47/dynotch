import Foundation

/// Reads a timer from what you type: "tea 4m", "laundry 45", "eggs 90s", "nap 1h30",
/// "pizza 12 min", "4:30 noodles". A number with no unit means minutes, and a number right
/// after a unit counts the next unit down, so "1h30" is an hour and a half.
enum TimerText {
    private enum Unit: Double {
        case hour = 3600, minute = 60, second = 1

        var smaller: Unit { self == .hour ? .minute : .second }

        init?(_ word: Substring) {
            switch word.lowercased() {
            case "h", "hr", "hrs", "hour", "hours": self = .hour
            case "m", "min", "mins", "minute", "minutes": self = .minute
            case "s", "sec", "secs", "second", "seconds": self = .second
            default: return nil
            }
        }
    }

    /// The longest timer it starts.
    static let maximum: TimeInterval = 24 * 3600

    static func parse(_ text: String) -> (name: String, duration: TimeInterval)? {
        let words = text.split(whereSeparator: \.isWhitespace).map(trimmed)
        var used = Set<Int>()
        var seconds: Double = 0
        var lastUnit: Unit?
        var index = 0
        while index < words.count {
            let word = words[index]
            let followsTime = used.contains(index - 1)
            if let clock = clock(word) {
                seconds += clock
                lastUnit = .second
                used.insert(index)
            } else if let (amount, unit) = compound(word) {
                seconds += amount
                lastUnit = unit
                used.insert(index)
            } else if let number = number(word), index + 1 < words.count, let unit = Unit(words[index + 1]) {
                seconds += number * unit.rawValue
                lastUnit = unit
                used.formUnion([index, index + 1])
                index += 1
            } else if let number = number(word), followsTime, let unit = lastUnit, unit != .second {
                seconds += number * unit.smaller.rawValue
                lastUnit = unit.smaller
                used.insert(index)
            }
            index += 1
        }
        // No units anywhere: the last number is minutes.
        if used.isEmpty, let last = words.indices.last(where: { number(words[$0]) != nil }), let minutes = number(words[last]) {
            seconds = minutes * 60
            used.insert(last)
        }
        guard seconds >= 1, seconds <= maximum else { return nil }

        var nameWords = words.indices.filter { !used.contains($0) }.map { words[$0] }.filter { !$0.isEmpty }
        if let last = nameWords.last, ["for", "in"].contains(last.lowercased()) { nameWords.removeLast() }
        if let first = nameWords.first, ["for", "in"].contains(first.lowercased()) { nameWords.removeFirst() }
        let name = String(nameWords.joined(separator: " ").prefix(30))
        return (name.isEmpty ? "Timer" : capitalized(name), seconds.rounded())
    }

    /// "45 s", "4 min", "4 min 30 s", "1 h 30 min"
    static func describe(_ duration: TimeInterval) -> String {
        let total = Int(duration.rounded())
        let hours = total / 3600, minutes = total / 60 % 60, seconds = total % 60
        if hours > 0 { return minutes == 0 ? "\(hours) h" : "\(hours) h \(minutes) min" }
        if minutes > 0 { return seconds == 0 ? "\(minutes) min" : "\(minutes) min \(seconds) s" }
        return "\(seconds) s"
    }

    // MARK: Pieces

    /// Without the commas and full stops around it.
    private static func trimmed(_ word: Substring) -> Substring {
        let isEdge = { (character: Character) in character.isPunctuation && character != ":" }
        guard let start = word.firstIndex(where: { !isEdge($0) }), let end = word.lastIndex(where: { !isEdge($0) }) else { return "" }
        return word[start...end]
    }

    private static func number(_ word: Substring) -> Double? {
        guard let first = word.first, first.isNumber || first == "." else { return nil }
        return Double(word.replacingOccurrences(of: ",", with: "."))
    }

    /// "4:30" is four and a half minutes; "1:05:00" is an hour and five minutes.
    private static func clock(_ word: Substring) -> Double? {
        let parts = word.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              parts.dropFirst().allSatisfy({ $0.count == 2 && Int($0)! < 60 }) else { return nil }
        return parts.reduce(0) { $0 * 60 + Double(Int($1)!) }
    }

    /// Numbers with units in one word: "4m", "90s", "1.5h", "1h30m", or "1h30" with the last unit implied.
    private static func compound(_ word: Substring) -> (seconds: Double, last: Unit)? {
        var runs: [Substring] = []
        var start = word.startIndex
        var index = word.startIndex
        while index < word.endIndex {
            let next = word.index(after: index)
            if next == word.endIndex || isDigit(word[index]) != isDigit(word[next]) {
                runs.append(word[start..<next])
                start = next
            }
            index = next
        }
        guard runs.count >= 2, isDigit(runs[0].first!) else { return nil }
        var seconds: Double = 0
        var last: Unit?
        var position = 0
        while position < runs.count {
            guard let amount = number(runs[position]) else { return nil }
            if position + 1 < runs.count {
                guard let unit = Unit(runs[position + 1]) else { return nil }
                seconds += amount * unit.rawValue
                last = unit
                position += 2
            } else {
                // A trailing number counts the next unit down: "1h30", "4m30".
                guard let unit = last, unit != .second else { return nil }
                seconds += amount * unit.smaller.rawValue
                last = unit.smaller
                position += 1
            }
        }
        return last.map { (seconds, $0) }
    }

    private static func isDigit(_ character: Character) -> Bool {
        character.isNumber || character == "." || character == ","
    }

    /// A capital first letter, unless the word is already mixed case, like "iPhone".
    private static func capitalized(_ name: String) -> String {
        guard let first = name.first, first.isLowercase else { return name }
        let second = name.dropFirst().first
        if let second, second.isUppercase { return name }
        return first.uppercased() + name.dropFirst()
    }
}
