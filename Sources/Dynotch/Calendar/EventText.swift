import Foundation

/// An event as typed: "dentist fri 3pm", "standup mon 9am 30m", "lunch tomorrow 12-1pm", "call fri 3pm est".
/// A misread title must never become an event, so this reads a short list of forms and says what's
/// wrong with anything else. A line needs a day `DayText` can read and a time that can only be read one
/// way, and the day has to stand beside the time or open the line. A time alone isn't taken to mean
/// today, because then "dentist wensday 3pm" would be. `NSDataDetector` isn't used here: it answers
/// almost anything, and differently by the hour it's asked.
enum EventText {
    /// What came of reading the text.
    enum Reading: Equatable {
        case event(NewEvent)
        /// No clock time in it. A day alone isn't enough.
        case noTime
        /// A time and no day that can be read, which is where a misspelled one ends up.
        case noDay
        /// A time that could be morning or afternoon, like "3:30" or "at 5".
        case needsAMOrPM
        /// When it ends, with nothing to say when it starts: "until 5pm".
        case noStart
        /// More than one time or day, and no telling which is meant.
        case severalTimes
        /// A day apart from the time, or one a word beside it changes: "black friday".
        case unclearDay
        /// Something that might be a time zone, but can't be read as one.
        case unclearZone
        /// A length that wasn't read: "for 3 days".
        case unclearLength
        /// A day the month doesn't have, a weekday the date doesn't fall on, or a time the clocks skip.
        case noSuchDate
        /// A time and nothing else.
        case noTitle
        /// A time that's already gone.
        case past(Date)
    }

    /// An hour, unless a length is typed.
    static let length: TimeInterval = 3600
    /// The longest a range of times can run, in minutes. "3pm-2pm" would be 23 hours.
    private static let longestRange = 16 * 60
    private static let wholeDay = 24 * 60

    static func read(_ text: String, now: Date = .now, calendar: Calendar = .current) -> Reading {
        let (body, typedLength) = pullLength(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
        var line = pieces(of: body)
        let days = line.compactMap(\.day)
        guard let place = line.firstIndex(where: { $0.clock != nil }), let clock = line[place].clock else { return .noTime }
        guard line.filter({ $0.clock != nil }).count == 1, days.count <= 1 else { return .severalTimes }
        // "until 5pm" can have the day between. "after tomorrow" is about the day, so that one can't.
        guard !endWords.contains(line[..<place].last { $0.word != nil }?.word?.lowercased() ?? ""),
              place == 0 || !["after", "before"].contains(line[place - 1].word?.lowercased() ?? "") else { return .noStart }

        let times: (start: Int, end: Int?)
        switch clock {
        case .invalid:
            return .noTime
        case .exact(let start, let end):
            times = (start, end)
        case .unsure(let minutes):
            // "tonight at 8" is the one place that says which.
            guard days.first == .tonight, let minutes, (5 * 60..<12 * 60).contains(minutes) else { return .needsAMOrPM }
            times = (minutes + 12 * 60, nil)
        }

        let zone = pullZone(after: place, from: &line)
        guard zone != .unclear else { return .unclearZone }
        let title = title(of: line)
        guard !title.isEmpty else { return .noTitle }
        let namesAnotherDay = title.range(of: otherDays, options: [.regularExpression, .caseInsensitive]) != nil
        guard namesAnotherDay || title.range(of: leftoverLength, options: [.regularExpression, .caseInsensitive]) == nil else { return .unclearLength }
        guard !hasAZoneBeforeTheTime(line) else { return .unclearZone }
        guard let day = days.first else { return .noDay }
        guard standsOnItsOwn(in: line), !namesAnotherDay else { return .unclearDay }

        var length = typedLength ?? Self.length
        if typedLength == nil, let end = times.end {
            let minutes = (end - times.start + wholeDay) % wholeDay
            guard minutes > 0, minutes <= longestRange else { return .severalTimes }
            length = TimeInterval(minutes * 60)
        }
        // The day is the one on the calendar here, whatever the zone. The clock is the one there.
        let local = DayText.gregorian(like: calendar)
        var there = local
        if case .zone(let zone) = zone { there.timeZone = zone }
        guard let date = DayText.day(day, now: now, calendar: local),
              let start = moment(on: date, at: times.start, local: local, there: there) else { return .noSuchDate }
        guard start >= now else { return .past(start) }
        return .event(NewEvent(title: title, start: start, end: start.addingTimeInterval(length)))
    }

    /// That clock time on that day, or nil when the clocks skip it. Midnight is the end of the day.
    private static func moment(on day: Date, at minutes: Int, local: Calendar, there: Calendar) -> Date? {
        guard let day = local.date(byAdding: .day, value: minutes / wholeDay, to: day) else { return nil }
        var parts = local.dateComponents([.year, .month, .day], from: day)
        parts.hour = minutes % wholeDay / 60
        parts.minute = minutes % 60
        guard let date = there.date(from: parts) else { return nil }
        let read = there.dateComponents([.hour, .minute], from: date)
        return read.hour == parts.hour && read.minute == parts.minute ? date : nil
    }

    // MARK: The line

    /// The line in order: its words, with the day and the time picked out of them.
    private enum Piece {
        case word(String)
        case day(DayText.Kind)
        case clock(Clock)

        var word: String? { if case .word(let word) = self { word } else { nil } }
        var day: DayText.Kind? { if case .day(let day) = self { day } else { nil } }
        var clock: Clock? { if case .clock(let clock) = self { clock } else { nil } }
    }

    private static func pieces(of text: String) -> [Piece] {
        var pieces: [Piece] = []
        func addWords(_ part: Substring) {
            pieces += part.split(whereSeparator: \.isWhitespace).map { .word(String($0)) }
        }
        func addClocks(_ part: String) {
            var position = part.startIndex
            for clock in clocks(in: part) {
                addWords(part[position..<clock.range.lowerBound])
                pieces.append(.clock(clock.clock))
                position = clock.range.upperBound
            }
            addWords(part[position...])
        }
        var position = text.startIndex
        for day in DayText.find(in: text) {
            addClocks(String(text[position..<day.range.lowerBound]))
            pieces.append(.day(day.kind))
            position = day.range.upperBound
        }
        addClocks(String(text[position...]))
        return pieces
    }

    /// What can stand between a day and a time, or lead up to either: "fri at 3pm", "sun, 3pm".
    private static let joiners: Set<String> = ["at", "@", "on", "from", ",", ".", ";", ":", "-", "–", "—"]

    private static func isJoiner(_ piece: Piece) -> Bool {
        piece.word.map { joiners.contains($0.lowercased()) } ?? false
    }

    /// What's left once the day, the time and the zone are out, without what only led up to them.
    private static func title(of line: [Piece]) -> String {
        let words = line.indices.compactMap { index -> String? in
            guard let word = line[index].word else { return nil }
            let leadsUp = index + 1 < line.count && line[index + 1].word == nil
            return leadsUp && isJoiner(line[index]) ? nil : word
        }
        let edges = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;:!?-–—"))
        return words.joined(separator: " ").trimmingCharacters(in: edges)
    }

    // MARK: The day

    /// Beside a day, these change which day it is, or show it's somebody: "black friday", "first
    /// monday", "lunch with sun", "the friday after next", "tuesday week".
    private static let wordsBefore: Set<String> = [
        "every", "each", "black", "good", "cyber", "easter", "palm", "ash", "holy", "first", "second", "third", "fourth", "fifth",
        "after", "before", "week", "weeks", "month", "following", "the", "with", "and", "or", "mr", "mrs", "ms", "dr",
    ]
    private static let wordsAfter: Set<String> = ["week", "fortnight", "after", "before", "next", "of"]

    /// Still in the title with a day read, these would move it: "dentist fri 3pm next week".
    private static let otherDays = #"\b(?:every|from now|next (?:week|month|year)|in (?:a|an|one|two|three|four|five|six|\d+) (?:days?|weeks?|wks?|months?|mos?|years?)|\d+ (?:days?|weeks?|months?) (?:from|after|before|later|ago))\b"#

    /// The day has to open the line or stand beside the time, which is what tells it from a word in
    /// the title, and nothing next to it can change it.
    private static func standsOnItsOwn(in line: [Piece]) -> Bool {
        guard let day = line.firstIndex(where: { $0.day != nil }), let clock = line.firstIndex(where: { $0.clock != nil }) else { return false }
        let opensTheLine = line[..<day].allSatisfy(isJoiner)
        let isBesideTheTime = line[(min(day, clock) + 1)..<max(day, clock)].allSatisfy(isJoiner)
        guard opensTheLine || isBesideTheTime else { return false }
        let before = line[..<day].last { !isJoiner($0) }?.word?.lowercased() ?? ""
        let after = line[(day + 1)...].first { !isJoiner($0) }?.word?.lowercased() ?? ""
        return !wordsBefore.contains(before) && !wordsAfter.contains(after)
            && before.range(of: #"^\d+(?:st|nd|rd|th)$"#, options: .regularExpression) == nil
    }

    // MARK: Times

    private enum Clock: Equatable {
        /// Minutes from midnight, up to a whole day for midnight itself.
        case exact(start: Int, end: Int?)
        /// No am or pm, and it could be either. A single time has its minutes here.
        case unsure(Int?)
        /// Not a time, like 13pm.
        case invalid
    }

    /// One end of a time.
    private struct Side {
        var hour = 0
        var minute = 0
        var hasMinutes = false
        /// "4.15" is as likely a version, so it takes more to count.
        var isDotted = false
        var hasLeadingZero = false
        var isPM: Bool?
        /// Noon or midnight, in minutes.
        var word: Int?

        /// From the groups of `side`: the hour, what's between it and the minutes, the minutes, am or pm, and a word.
        init?(_ groups: ArraySlice<String?>) {
            let groups = Array(groups)
            if let word = groups[4] {
                self.word = word == "noon" ? 12 * 60 : EventText.wholeDay
            } else if let digits = groups[0], let hour = Int(digits) {
                self.hour = hour
                minute = groups[2].flatMap { Int($0) } ?? 0
                hasMinutes = groups[2] != nil
                isDotted = groups[1] == "."
                hasLeadingZero = digits.hasPrefix("0") && digits.count == 2
                isPM = groups[3].map { $0 == "p" }
            } else {
                return nil
            }
        }

        /// A number alone isn't a time, so "sprint 12" stays in the title.
        var countsAlone: Bool { word != nil || isPM != nil || (hasMinutes && (!isDotted || hour >= 13)) }

        var clock: Clock {
            if let word { return .exact(start: word, end: nil) }
            guard minute < 60 else { return .invalid }
            if let isPM {
                guard (1...12).contains(hour) else { return .invalid }
                return .exact(start: (hour % 12 + (isPM ? 12 : 0)) * 60 + minute, end: nil)
            }
            guard hour <= 23, hour > 0 || hasMinutes || hasLeadingZero else { return .invalid }
            let minutes = hour * 60 + minute
            return hour >= 13 || hour == 0 || hasLeadingZero ? .exact(start: minutes, end: nil) : .unsure(minutes)
        }
    }

    private static let side = #"(?:(\d{1,2})(?:([:.])(\d{2}))?(?:\s*([ap])\.?m\b\.?)?|(noon|midnight))"#
    private static let upTo = #"\s*(?:-|–|—|\bto\b|\buntil\b|\btill\b|\btil\b)\s*"#

    private static func clocks(in text: String) -> [(clock: Clock, range: Range<String.Index>)] {
        let pattern = #"(?<![\w:./-])((?:at|@)\s*)?"# + side + #"(?:"# + upTo + side + #")?(?![\w:/-]|\.\d)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let groups = (0..<match.numberOfRanges).map { index in Range(match.range(at: index), in: text).map { String(text[$0]).lowercased() } }
            guard let first = Side(groups[2...6]) else { return nil }
            let second = Side(groups[7...11])
            guard groups[1] != nil || first.countsAlone || second?.countsAlone == true else { return nil }
            return (clock(from: first, to: second), range)
        }
    }

    private static func clock(from first: Side, to second: Side?) -> Clock {
        guard let second else { return first.clock }
        switch (first.clock, second.clock) {
        case (.invalid, _), (_, .invalid):
            return .invalid
        case (.exact(let start, _), .exact(let end, _)):
            return .exact(start: start, end: end)
        case (.unsure, .exact(let end, _)):
            return second.isPM.map { range(from: first, to: end, isPM: $0) } ?? .unsure(nil)
        default:
            return .unsure(nil)
        }
    }

    /// "3-4pm": the end speaks for the start, or "11-1pm" goes across noon. What runs past midnight from
    /// one end or the other, like "9-2am", is left to say which, and so is "12-1am".
    private static func range(from first: Side, to end: Int, isPM: Bool) -> Clock {
        guard first.hour != 12 || isPM else { return .unsure(nil) }
        for isPM in [isPM, !isPM] {
            var side = first
            side.isPM = isPM
            if case .exact(let start, _) = side.clock, start < end { return .exact(start: start, end: end) }
        }
        return .unsure(nil)
    }

    /// Ahead of the time, these make it an end rather than a start.
    private static let endWords: Set<String> = ["until", "till", "til", "end", "ends", "ending", "finish", "finishes", "finishing"]

    // MARK: Lengths

    /// "for 45 min", "for an hour" and "for half an hour" anywhere, or a length with its unit at the
    /// very end. A number alone is too easily something else, and a length up front is as likely to be
    /// in the title: "2h workshop fri 3pm".
    private static func pullLength(from text: String) -> (text: String, length: TimeInterval?) {
        let minutes = #"(?:m|min|mins|minute|minutes)"#
        let hours = #"\d+(?:[.,]\d+)?\s*(?:h|hr|hrs|hour|hours)(?:\s*(?:and\s+)?\d+\s*"# + minutes + #"?(?![\d:.]))?"#
        let amount = #"(?:half an hour|an hour|"# + hours + #"|\d+(?:[.,]\d+)?\s*"# + minutes + #")"#
        for pattern in [#"\bfor\s+("# + amount + #")\b"#, #"\s("# + amount + #")\s*$"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let whole = Range(match.range, in: text), let group = Range(match.range(at: 1), in: text),
                  let length = seconds(in: String(text[group])), length >= 60 else { continue }
            var rest = text
            rest.replaceSubrange(whole, with: " ")
            return (rest.trimmingCharacters(in: .whitespaces), length)
        }
        return (text, nil)
    }

    private static func seconds(in amount: String) -> TimeInterval? {
        switch amount.lowercased() {
        case "half an hour": 1800
        case "an hour": 3600
        default: TimerText.parse(amount.replacingOccurrences(of: " and ", with: " ").replacingOccurrences(of: ",", with: "."))?.duration
        }
    }

    /// A length that's still in the title: too long, or in days.
    private static let leftoverLength = #"\bfor\s+\d+(?:[.,]\d+)?\s*(?:h|hrs?|hours?|m|mins?|minutes?|days?|weeks?|months?)\b|\b\d+\s*(?:days?|weeks?|months?)$"#

    // MARK: Zones

    private enum TypedZone: Equatable {
        case none
        case zone(TimeZone)
        case unclear
    }

    /// Zones that hardly mean anything else.
    private static let commonZones: Set<String> = ["est", "edt", "pst", "pdt", "cst", "cdt", "mst", "mdt", "gmt", "utc", "cet", "cest", "ist", "jst", "pkt", "aest"]
    /// Initials that are words first. In capitals they're zones.
    private static let wordsNotZones: Set<String> = ["aft", "art", "cat", "cot", "eat", "pet", "wat", "west", "wet", "wit"]

    /// Takes a zone from the end of the line. It only counts with nothing after it but the day, so in
    /// "meet fri 3pm sgt jones" and "fri 3pm PT session" it's part of the title.
    private static func pullZone(after clock: Int, from line: inout [Piece]) -> TypedZone {
        let tail = line.indices.filter { $0 > clock && line[$0].word != nil && !isJoiner(line[$0]) }
        let words = tail.compactMap { line[$0].word }
        guard let first = words.first else { return .none }
        func take(_ zone: TypedZone) -> TypedZone {
            for index in tail.reversed() { line.remove(at: index) }
            return zone
        }
        if words.count > 1, commonZones.contains(first.lowercased()) { return .unclear }
        if (2...4).contains(words.count), words.last?.lowercased() == "time" {
            let name = words.dropLast().joined(separator: " ")
            if name.lowercased() == "local" { return take(.none) }
            guard let place = WorldTime.place(name) else { return .unclear }
            return take(.zone(place.zone))
        }
        guard words.count == 1 else { return .none }
        // "(est)" and "e.s.t." are that zone, and "et/pt" and "gmt+5" can't be read as one.
        let typed = first.filter { $0 != "." }.trimmingCharacters(in: CharacterSet(charactersIn: "()[],"))
        let parts = typed.split { !$0.isLetter }.map(String.init)
        guard parts == [typed] else { return parts.contains { WorldTime.initials($0) != nil } ? .unclear : .none }
        guard let place = WorldTime.initials(typed) else { return .none }
        let isInCapitals = typed == typed.uppercased()
        if !isInCapitals, wordsNotZones.contains(typed.lowercased()) { return .none }
        // "gym fri 6pm pt" could be either.
        if !isInCapitals, typed.count == 2 { return .unclear }
        return take(.zone(place.zone))
    }

    /// "call est 3pm", "call lahore time fri 3pm": a zone ahead of the time, where it isn't read.
    /// Initials that mean other things too, as "gst" and "bst" do, go for part of the title.
    private static func hasAZoneBeforeTheTime(_ line: [Piece]) -> Bool {
        line.indices.filter { line[$0].word == nil }.contains { mark in
            let words = line[..<mark].reversed().prefix { $0.word != nil }.compactMap { $0.word?.lowercased() }
            guard let last = words.first else { return false }
            guard last == "time" else { return commonZones.contains(last) }
            return (1...2).contains { count in
                words.count > count && WorldTime.place(words[1...count].reversed().joined(separator: " ")) != nil
            }
        }
    }
}
