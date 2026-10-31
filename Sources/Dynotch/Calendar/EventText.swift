import Foundation

/// An event as typed: "dentist fri 3pm", "standup mon 9am 30m", "lunch fri 12-1pm". What can't be
/// read is said out loud rather than guessed at, since a misread title must never become an event:
/// `NSDataDetector` hands back noon for "dentist fri", and the 3rd of the month for "friday 3".
enum EventText {
    /// What came of reading the text.
    enum Reading: Equatable {
        case event(NewEvent)
        /// No time in it, or nothing that's clearly one.
        case noTime
        /// More than one time or date, and no telling which is meant.
        case severalTimes
        /// A time and nothing else.
        case noTitle
        /// A day that's already gone, or a time on one.
        case past(Date)
    }

    /// An hour, unless a length is typed.
    static let length: TimeInterval = 3600

    /// A date the detector found.
    private struct Found {
        let range: Range<String.Index>
        let date: Date
        let duration: TimeInterval
        let isZoned: Bool
        let hasTime: Bool
    }

    static func read(_ text: String, now: Date = .now) -> Reading {
        let (body, typedLength) = pullLength(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return .noTime }
        let found = detector.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap { match -> Found? in
            guard let range = Range(match.range, in: body), let date = match.date else { return nil }
            return Found(range: range, date: date, duration: match.duration, isZoned: match.timeZone != nil, hasTime: hasTime(body[range]))
        }
        let days = found.filter { !$0.hasTime }
        guard let time = found.first(where: \.hasTime) else { return .noTime }
        guard found.count - days.count == 1, days.count <= 1 else { return .severalTimes }

        var start = time.date
        var isBare = isBareTime(body[time.range], hasZone: time.isZoned)
        // "fri dentist 3pm" comes back as a day at noon and a time today.
        if let day = days.first {
            guard isBare, !time.isZoned, let joined = date(day.date, at: time.date) else { return .severalTimes }
            start = joined
            isBare = false
        }
        let title = title(of: body, without: found.map(\.range))
        guard !title.isEmpty else { return .noTitle }
        if start < now {
            // "5pm" typed at six means tomorrow's. "fri 5pm", or "today 5pm", can only mean what it says.
            guard isBare, let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return .past(start) }
            start = tomorrow
        }
        let length = typedLength ?? (time.duration > 0 ? time.duration.rounded() : Self.length)
        return .event(NewEvent(title: title, start: start, end: start.addingTimeInterval(length)))
    }

    // MARK: Pieces

    /// "for 45 min" anywhere, or a length with its unit at the very end. A number alone is too easily
    /// something else, and a length up front is as likely to be in the title: "2h workshop fri 3pm".
    private static func pullLength(from text: String) -> (text: String, length: TimeInterval?) {
        let amount = #"\d+(?:[.,]\d+)?\s*(?:h|hr|hrs|hour|hours|m|min|mins|minute|minutes)(?:\s*\d+\s*(?:m|min|mins|minutes)?)?"#
        for pattern in [#"\bfor\s+("# + amount + #")\b"#, #"\s("# + amount + #")\s*$"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let whole = Range(match.range, in: text), let group = Range(match.range(at: 1), in: text),
                  let length = TimerText.parse(String(text[group]))?.duration, length >= 60 else { continue }
            var rest = text
            rest.removeSubrange(whole)
            return (rest.trimmingCharacters(in: .whitespaces), length)
        }
        return (text, nil)
    }

    /// There's a clock time in what the detector matched, rather than a day it set to noon.
    private static func hasTime(_ text: Substring) -> Bool {
        text.range(of: #"\d\s*[ap]\.?(?:m\b|\.|\b)|\d[:.]\d{2}\b|\bat\s+\d|\b(?:noon|midnight|tonight|morning|afternoon|evening)\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Only a time, with no day: "3pm", "at 15:30", "12-1pm", "3pm pst".
    private static func isBareTime(_ text: Substring, hasZone: Bool) -> Bool {
        let time = #"(?:\d{1,2}(?:[:.]\d{2})?\s*(?:[ap]\.?(?:m\.?)?)?|noon|midnight)"#
        let meal = #"(?:(?:breakfast|brunch|lunch|dinner|supper)\s+)?"#
        let zone = hasZone ? #"(?:\s+[a-z]{2,5})?"# : ""
        let pattern = #"^"# + meal + #"(?:(?:at|from)\s+)?"# + time + #"(?:\s*(?:-|–|to|until)\s*"# + time + #")?"# + zone + #"$"#
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// `day`, at the clock time of `time`.
    private static func date(_ day: Date, at time: Date) -> Date? {
        let calendar = Calendar.current
        let clock = calendar.dateComponents([.hour, .minute], from: time)
        return clock.hour.flatMap { calendar.date(bySettingHour: $0, minute: clock.minute ?? 0, second: 0, of: day) }
    }

    /// What's left once the dates are out. The detector takes a meal for a time of day, so "lunch" is
    /// part of what it matched, where for an event it's the name.
    private static func title(of text: String, without ranges: [Range<String.Index>]) -> String {
        var title = text
        for range in ranges.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            let meal = text[range].split(separator: " ").first { ["breakfast", "brunch", "lunch", "dinner", "supper"].contains($0.lowercased()) }
            title.replaceSubrange(range, with: meal.map { " \($0) " } ?? " ")
        }
        title = title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        // Whatever led up to the date, which the title has no more use for.
        for word in ["at", "on", "by", "for", "from", "this", "next"] {
            if title.lowercased() == word { return "" }
            if title.lowercased().hasSuffix(" " + word) { title = String(title.dropLast(word.count + 1)) }
        }
        return title.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    }
}
