import Foundation

/// An event as typed: "dentist fri 3pm", "standup mon 9am 30m", "lunch fri 12-1pm", "call fri 3pm est".
/// A misread title must never become an event, and `NSDataDetector` will answer most things: noon for
/// "dentist fri", the 3rd of the month for "friday 3", July for "24/7", December for "nov 31", and
/// today for "dentist tomorow 3pm", with the misspelled word left in the title. So nothing it says is
/// taken at its word. A time has to be a clock time that can only be read one way, every date in the
/// line has to be accounted for, and what's left for the title can't look like a date it missed.
/// Anything else is said in the row rather than guessed at.
enum EventText {
    /// What came of reading the text.
    enum Reading: Equatable {
        case event(NewEvent)
        /// No clock time in it. A day alone isn't enough.
        case noTime
        /// A time that could be morning or afternoon, like "3:30" or "at 5".
        case needsAMOrPM
        /// When it ends, with nothing to say when it starts: "until 5pm".
        case noStart
        /// More than one time or date, and no telling which is meant.
        case severalTimes
        /// Something left in the title looks like a day that wasn't read.
        case unclearDay
        /// A time zone that isn't right after the time.
        case unclearZone
        /// A length that wasn't read: "for 3 days".
        case unclearLength
        /// A day the month doesn't have.
        case noSuchDate
        /// A time and nothing else.
        case noTitle
        /// A day that's already gone, or a time on one.
        case past(Date)
    }

    /// An hour, unless a length is typed.
    static let length: TimeInterval = 3600
    /// The longest a range can run without naming a second day. "3pm-2pm" reads as 23 hours.
    private static let longestRange: TimeInterval = 16 * 3600

    private enum Clock {
        /// A time that can only mean one thing.
        case exact
        /// A time with no am or pm that could be either.
        case ambiguous
        /// No time: the detector gave a day noon of its own accord.
        case none
    }

    /// A date the detector found.
    private struct Found {
        let range: Range<String.Index>
        let date: Date
        let duration: TimeInterval
        let isZoned: Bool
        let clock: Clock
    }

    static func read(_ text: String, now: Date = .now) -> Reading {
        let (body, typedLength) = pullLength(from: spellingOutSunday(in: text.trimmingCharacters(in: .whitespacesAndNewlines)))
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return .noTime }
        let found = detector.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap { match -> Found? in
            guard let range = Range(match.range, in: body), let date = match.date else { return nil }
            return Found(range: range, date: date, duration: match.duration, isZoned: match.timeZone != nil, clock: clock(in: body[range]))
        }
        let days = found.filter { $0.clock == .none }
        guard let time = found.first(where: { $0.clock != .none }) else { return .noTime }
        guard found.count - days.count == 1, days.count <= 1 else { return .severalTimes }
        guard time.clock == .exact else { return .needsAMOrPM }
        let timeText = body[time.range]
        guard timeText.range(of: #"\b(?:until|till|til)\b"#, options: [.regularExpression, .caseInsensitive]) == nil else { return .noStart }

        var start = time.date
        var isBare = isBareTime(timeText, hasZone: time.isZoned)
        // "fri dentist 3pm" comes back as a day at noon and a time today.
        if let day = days.first {
            // A bare "24/7" or "11/12" is as likely to be part of the title.
            guard isBare, !time.isZoned, body[day.range].contains(where: \.isLetter), let joined = date(day.date, at: time.date) else { return .severalTimes }
            start = joined
            isBare = false
        }
        let dateText = found.map { String(body[$0.range]) }.joined(separator: " ")
        // "nov 31" comes back as the 1st of December.
        if !time.isZoned, let typed = DateText.typedDay(in: dateText), typed != Calendar.current.component(.day, from: start) { return .noSuchDate }

        var taken = found.map(\.range)
        if !time.isZoned, let zone = zone(after: time.range, in: body) {
            taken.append(zone.range)
            start = date(start, in: zone.zone)
        }
        let title = title(of: body, without: taken)
        guard !title.isEmpty else { return .noTitle }
        guard title.range(of: leftoverLength, options: [.regularExpression, .caseInsensitive]) == nil else { return .unclearLength }
        guard !looksLikeADate(title, hasDay: !isBare) else { return .unclearDay }
        guard !endsInAZone(title) else { return .unclearZone }

        // "fri" typed on a Friday comes back as next week, however much of today is left.
        if !isBare, let today = todaysOccurrence(of: start, named: dateText, now: now) { start = today }
        if start < now {
            // "5pm" typed at six means tomorrow's. "fri 5pm", or "today 5pm", can only mean what it says.
            guard isBare, let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return .past(start) }
            start = tomorrow
        }
        var length = typedLength ?? Self.length
        if typedLength == nil, time.duration > 0 {
            guard time.duration <= longestRange || namesTwoDays(timeText) else { return .severalTimes }
            length = time.duration.rounded()
        }
        return .event(NewEvent(title: title, start: start, end: start.addingTimeInterval(length)))
    }

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
            rest.removeSubrange(whole)
            return (rest.trimmingCharacters(in: .whitespaces), length)
        }
        return (text, nil)
    }

    private static func seconds(in amount: String) -> TimeInterval? {
        switch amount.lowercased() {
        case "half an hour": 1800
        case "an hour": 3600
        default: TimerText.parse(amount.replacingOccurrences(of: " and ", with: " "))?.duration
        }
    }

    /// A length that's still in the title: too long, or in days.
    private static let leftoverLength = #"\bfor\s+\d+(?:[.,]\d+)?\s*(?:h|hrs?|hours?|m|mins?|minutes?|days?|weeks?|months?)\b"#

    // MARK: Times

    /// What the detector found holds a time, as far as can be told from how it's written.
    private static func clock(in text: Substring) -> Clock {
        func has(_ pattern: String) -> Bool { text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
        let marked = #"(?<![\d.:/])(\d{1,2})(?:[:.][0-5]\d)?\s*[ap]\.?(?:m\b\.?|\b)"#
        if has(marked) {
            // 13pm is no time, and the detector takes it for one.
            let hours = (try? NSRegularExpression(pattern: marked, options: .caseInsensitive))?
                .matches(in: String(text), range: NSRange(location: 0, length: (String(text) as NSString).length))
                .compactMap { Int((String(text) as NSString).substring(with: $0.range(at: 1))) } ?? []
            return hours.allSatisfy { (1...12).contains($0) } ? .exact : .none
        }
        if has(#"(?<![\d.:/-])(?:0\d|1[3-9]|2[0-3])[:.][0-5]\d(?![\d.:/-])"#) || has(#"\bat\s+(?:1[3-9]|2[0-3])\b(?![-/.:\d])"#)
            || has(#"\b(?:noon|midnight)\b"#) || has(#"\btonight\s+at\s+\d{1,2}\b(?![-/.:\d])"#) { return .exact }
        if has(#"(?<![\d.:/-])\d{1,2}[:.][0-5]\d(?![\d.:/-])"#) || has(#"\bat\s+\d{1,2}\b(?![-/.:\d])"#) { return .ambiguous }
        return .none
    }

    /// Only a time, with no day: "3pm", "at 15:30", "12-1pm", "3pm pst".
    private static func isBareTime(_ text: Substring, hasZone: Bool) -> Bool {
        let time = #"(?:\d{1,2}(?:[:.]\d{2})?\s*(?:[ap]\.?(?:m\.?)?)?|noon|midnight)"#
        let meal = #"(?:(?:breakfast|brunch|lunch|dinner|supper)\s+)?"#
        let zone = hasZone ? #"(?:\s+[a-z]{2,5})?"# : ""
        let pattern = #"^"# + meal + #"(?:(?:at|from)\s+)?"# + time + #"(?:\s*(?:-|–|to)\s*"# + time + #")?"# + zone + #"$"#
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// `day`, at the clock time of `time`.
    private static func date(_ day: Date, at time: Date) -> Date? {
        let calendar = Calendar.current
        let clock = calendar.dateComponents([.hour, .minute], from: time)
        return clock.hour.flatMap { calendar.date(bySettingHour: $0, minute: clock.minute ?? 0, second: 0, of: day) }
    }

    /// The same clock time and date, in `zone`.
    private static func date(_ date: Date, in zone: TimeZone) -> Date {
        var there = Calendar(identifier: .gregorian)
        there.timeZone = zone
        return there.date(from: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)) ?? date
    }

    // MARK: Days

    /// The one short weekday the detector doesn't read, right before a time. Anywhere else it's left
    /// for the check on what's in the title.
    private static func spellingOutSunday(in text: String) -> String {
        text.replacingOccurrences(of: #"(?i)\bsun\b(?=\s+(?:at\s+)?(?:\d|noon|midnight))"#, with: "sunday", options: .regularExpression)
    }

    /// A weekday typed on that weekday comes back a week on. With the time still ahead, it means today,
    /// unless it says "next".
    private static func todaysOccurrence(of date: Date, named text: String, now: Date) -> Date? {
        let calendar = Calendar.current
        guard text.range(of: weekdayName, options: [.regularExpression, .caseInsensitive]) != nil,
              text.range(of: #"\bnext\b"#, options: [.regularExpression, .caseInsensitive]) == nil,
              let sooner = calendar.date(byAdding: .day, value: -7, to: date),
              calendar.isDate(sooner, inSameDayAs: now), sooner > now else { return nil }
        return sooner
    }

    private static let weekdayName = #"\b(?:mon|tue|wed|thu|fri|sat|sun)[a-z]*\b"#

    /// A range over 16 hours has to say which two days it runs between.
    private static func namesTwoDays(_ text: Substring) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: weekdayName + #"|\btomorrow\b"#, options: .caseInsensitive) else { return false }
        let line = String(text) as NSString
        return Set(regex.matches(in: String(text), range: NSRange(location: 0, length: line.length)).map {
            line.substring(with: $0.range).lowercased().prefix(3)
        }).count >= 2
    }

    // MARK: The title

    /// Words the detector takes for a time of day, so they're part of what it matched. For an event
    /// they're the name.
    private static let namingWords: Set<String> = ["breakfast", "brunch", "lunch", "dinner", "supper", "night"]

    /// What's left once the dates are out.
    private static func title(of text: String, without ranges: [Range<String.Index>]) -> String {
        var title = text
        for range in ranges.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            let kept = text[range].split(separator: " ").first { namingWords.contains($0.lowercased()) }
            title.replaceSubrange(range, with: kept.map { " \($0) " } ?? " ")
        }
        let edges = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;:!?-–—"))
        title = title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: edges)
        // Whatever led up to the date, which the title has no more use for.
        for word in ["at", "on", "for", "from", "this", "next"] {
            if title.lowercased() == word { return "" }
            if title.lowercased().hasSuffix(" " + word) { title = String(title.dropLast(word.count + 1)) }
        }
        for word in ["at", "on"] where title.lowercased().hasPrefix(word + " ") { title = String(title.dropFirst(word.count + 1)) }
        return title.trimmingCharacters(in: edges)
    }

    /// Dates that were left in the title because nothing read them. These speak for a date whatever else
    /// was read: weekdays, days from now, and anything every week, which one event can't be.
    private static let dateWords = #"\b(?:mon|tues?|wed|weds|thu|thur|thurs|fri|fir|frid|sat|sun|mondays?|tuesdays?|wednesdays?|thursdays?|fridays?|saturdays?|sundays?"#
        + #"|today|tonight|tomorrow|yesterday|tmr|tmrw|tmw|tomo|2moro|2morrow|every|from now"#
        + #"|(?:next|this) (?:week|month|year)|(?:a|one|two|\d+) (?:days?|weeks?|months?)(?: (?:from|after|before)|$)|in (?:a|one|two|\d+) (?:days?|weeks?|months?|years?))\b"#
    /// These only count when no day was read: "weekend trip sat 9am" and "call june fri 3pm" are fine.
    private static let dayWords = #"\b(?:jan|feb|mar|apr|jun|jul|aug|sept?|oct|nov|dec|january|february|march|april|june|july|august|september|october|november|december"#
        + #"|weekends?|fortnight|christmas|xmas|thanksgiving|easter|halloween|new year)\b"#

    private static func looksLikeADate(_ title: String, hasDay: Bool) -> Bool {
        func has(_ pattern: String) -> Bool { title.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
        if has(dateWords) || (!hasDay && has(dayWords)) { return true }
        // Near enough to a day that it's a slip of the finger. "Sandy" and "Mandy" are two letters off.
        let days = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
        return title.lowercased().split(whereSeparator: { !$0.isLetter }).contains { word in
            word.count >= 5 && (days.contains { editDistance(word, $0) <= 1 } || editDistance(word, "tomorrow") <= 2)
        }
    }

    /// Letters to add, drop or change, or a pair to swap, to get from one word to the other.
    private static func editDistance(_ first: Substring, _ second: String) -> Int {
        let (a, b) = (Array(first), Array(second))
        guard abs(a.count - b.count) <= 2 else { return 3 }
        var table = (0...a.count).map { row in (0...b.count).map { row == 0 ? $0 : $0 == 0 ? row : 0 } }
        for i in 1...a.count {
            for j in 1...b.count {
                table[i][j] = min(table[i - 1][j] + 1, table[i][j - 1] + 1, table[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { table[i][j] = min(table[i][j], table[i - 2][j - 2] + 1) }
            }
        }
        return table[a.count][b.count]
    }

    // MARK: Zones

    /// Initials that are words first. "dentist 3pm art class" has nothing to do with Argentina.
    private static let wordsNotZones: Set<String> = ["art", "cat", "cot", "eat", "pet", "wat", "west", "wet", "wit"]

    private static func zoneInitials(_ word: String) -> WorldPlace? {
        wordsNotZones.contains(word.lowercased()) ? nil : WorldTime.initials(word)
    }

    /// A zone the detector left behind, right after the time: it reads "PST" and "pst", but not "est",
    /// "pkt" or "lahore time". The two-letter ones only count at the very end, as "pt" and "ct" mean
    /// other things in the middle of a line.
    private static func zone(after range: Range<String.Index>, in text: String) -> (range: Range<String.Index>, zone: TimeZone)? {
        let rest = text[range.upperBound...]
        if let match = rest.range(of: #"^\s+[A-Za-z ]{2,30}?\s+time\b"#, options: .regularExpression) {
            let name = rest[match].dropLast(4).trimmingCharacters(in: .whitespaces)
            if let place = WorldTime.place(name) { return (match, place.zone) }
        }
        guard let match = rest.range(of: #"^\s+[A-Za-z]{2,5}\b"#, options: .regularExpression) else { return nil }
        let word = rest[match].trimmingCharacters(in: .whitespaces)
        guard let place = zoneInitials(word), word.count > 2 || match.upperBound == rest.endIndex else { return nil }
        return (match, place.zone)
    }

    /// "call est 3pm", or "call lahore time 3pm": a zone that isn't where it could be read.
    private static func endsInAZone(_ title: String) -> Bool {
        let words = title.split(separator: " ").map(String.init)
        guard let last = words.last else { return false }
        if last.count > 2, zoneInitials(last) != nil { return true }
        guard last.lowercased() == "time", words.count > 1 else { return false }
        return (1...min(3, words.count - 1)).contains { count in WorldTime.place(words.dropLast().suffix(count).joined(separator: " ")) != nil }
    }
}
