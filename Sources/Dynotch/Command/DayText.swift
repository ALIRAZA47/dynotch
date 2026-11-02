import Foundation

/// A day as typed, read by rule rather than by `NSDataDetector`, which rolls "nov 31" into December,
/// takes "24/7" for July, and answers differently by the hour it's asked. These are the forms, and
/// anything else stays text, for whatever's reading to say so:
///
/// `today`, `tonight`, `this evening`, `tomorrow`, `tmrw`, `yesterday`, `fri`, `friday night`, `next fri`,
/// `this fri`, `last fri`, `25 dec`, `dec 25`, `25th of december`, `dec 25 2026`, `2026-12-25`, and a
/// weekday in front of a date, as in `fri dec 25` or `fri 13th`, which has to agree with it. Numbers with
/// slashes aren't read unless the year's first, as `5/11` is two different days depending on who wrote it.
enum DayText {
    enum Kind: Equatable {
        case today, tomorrow, yesterday
        /// 1 for Sunday, as `Calendar` counts.
        case weekday(Int, Which)
        /// `month` is nil for "fri 13th", which is the coming 13th. A `weekday` has to fall on the date.
        case date(year: Int?, month: Int?, day: Int, weekday: Int?)
    }

    /// Which one a weekday means: "fri", "next fri" or "last fri".
    enum Which { case coming, next, last }

    /// The part of a day named with it: "friday night", "tonight".
    enum Part {
        case morning, afternoon, evening, night

        /// The minutes it covers, up to midnight at the end of the day.
        var minutes: ClosedRange<Int> {
            switch self {
            case .morning: (4 * 60)...(12 * 60 - 1)
            case .afternoon: (12 * 60)...(18 * 60 - 1)
            case .evening: (16 * 60)...(24 * 60)
            case .night: (17 * 60)...(24 * 60)
            }
        }
    }

    struct Found: Equatable {
        let kind: Kind
        let part: Part?
        let range: Range<String.Index>
    }

    /// Past this it's a paste rather than a day, and the search takes a noticeable time.
    private static let longestText = 500
    private static let weekdays = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let weekdayName = #"(mon(?:day)?|tue(?:s|sday)?|wed(?:s|nesday)?|thu(?:r|rs|rsday)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?)"#
    private static let monthName = #"(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sept?(?:ember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)"#
    private static let ordinal = #"(?:st|nd|rd|th)"#
    private static let partName = #"(?:\s+(morning|afternoon|evening|night)\b)?"#
    /// A weekday in front of a date.
    private static let beside = #"(?:"# + weekdayName + #"(?:['’]s)?,?\s+)?(?:the\s+)?"#
    /// A year after a date, which can't run into a time.
    private static let year = #"(?:,?\s+([0-9]{4})(?![\w:.-]))?"#

    /// The days in `text`, in order, and none overlapping another.
    static func find(in text: String) -> [Found] {
        guard text.utf16.count <= longestText else { return [] }
        var found: [Found] = []
        func read(_ pattern: String, as day: ([String?]) -> (kind: Kind, part: Part?)?) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text), !found.contains(where: { $0.range.overlaps(range) }) else { continue }
                let groups = (1..<match.numberOfRanges).map { index in Range(match.range(at: index), in: text).map { String(text[$0]) } }
                if let day = day(groups) { found.append(Found(kind: day.kind, part: day.part, range: range)) }
            }
        }
        read(#"(?<![\w/.:-])"# + beside + #"([0-9]{4})[-/]([0-9]{1,2})[-/]([0-9]{1,2})(?![\w/.:-])"#) { groups in
            date(weekday: groups[0], year: groups[1], month: groups[2].flatMap { Int($0) }, day: groups[3])
        }
        read(#"(?<![\w:./-])"# + beside + #"([0-9]{1,2})"# + ordinal + #"?\s+(?:of\s+)?"# + monthName + #"\b\.?"# + year) { groups in
            date(weekday: groups[0], year: groups[3], month: month(named: groups[2]), day: groups[1])
        }
        read(#"(?<![\w:./-])"# + beside + monthName + #"\b\.?\s+(?:the\s+)?([0-9]{1,2})"# + ordinal + #"?(?![\w:./-])(?!\s*[ap]\.?m\b)"# + year) { groups in
            date(weekday: groups[0], year: groups[3], month: month(named: groups[1]), day: groups[2])
        }
        read(#"(?<![\w-])"# + weekdayName + #"(?:['’]s)?\s+(?:the\s+)?([0-9]{1,2})"# + ordinal + #"\b"#) { groups in
            date(weekday: groups[0], year: nil, month: nil, day: groups[1])
        }
        read(#"\b(today|tonight|tomorrow|tmrw|tmr|tmw|yesterday)(?:['’]s)?\b"# + partName) { groups in
            switch groups[0]?.lowercased() {
            case "today": (.today, part(named: groups[1]))
            case "tonight": (.today, .night)
            case "yesterday": (.yesterday, part(named: groups[1]))
            default: (.tomorrow, part(named: groups[1]))
            }
        }
        read(#"\bthis\s+(morning|afternoon|evening)\b"#) { groups in (.today, part(named: groups[0])) }
        // Not "mon-fri", which is a run of days rather than a day.
        read(#"(?<![\w-])(?:(next|this|last)(?:\s+coming)?\s+)?"# + weekdayName + #"(?:['’]s)?\b(?!-)"# + partName) { groups in
            let which: Which = switch groups[0]?.lowercased() {
            case "next": .next
            case "last": .last
            default: .coming
            }
            return weekday(named: groups[1]).map { (.weekday($0, which), part(named: groups[2])) }
        }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private static func weekday(named name: String?) -> Int? {
        guard let name = name?.lowercased() else { return nil }
        return weekdays.firstIndex { name.hasPrefix($0) }.map { $0 + 1 }
    }

    private static func month(named name: String?) -> Int? {
        guard let name = name?.lowercased() else { return nil }
        return months.firstIndex { name.hasPrefix($0) }.map { $0 + 1 }
    }

    private static func part(named name: String?) -> Part? {
        switch name?.lowercased() {
        case "morning": .morning
        case "afternoon": .afternoon
        case "evening": .evening
        case "night": .night
        default: nil
        }
    }

    private static func date(weekday name: String?, year: String?, month: Int?, day: String?) -> (kind: Kind, part: Part?)? {
        guard let day = day.flatMap({ Int($0) }) else { return nil }
        return (.date(year: year.flatMap { Int($0) }, month: month, day: day, weekday: weekday(named: name)), nil)
    }

    /// The day `kind` means, seen from `now`: the coming one, or the last one when `looksBack`. Nil when
    /// there's no such day. `calendar` has to be Gregorian, as the names and numbers here are.
    static func day(_ kind: Kind, now: Date, calendar: Calendar, looksBack: Bool = false) -> Date? {
        let today = calendar.startOfDay(for: now)
        func away(_ days: Int) -> Date? { calendar.date(byAdding: .day, value: days, to: today) }
        func first(_ days: some Sequence<Int>, where isIt: (Date) -> Bool) -> Date? {
            days.lazy.compactMap(away).first(where: isIt)
        }
        let step = looksBack ? -1 : 1
        switch kind {
        case .today:
            return today
        case .tomorrow:
            return away(1)
        case .yesterday:
            return away(-1)
        case .weekday(let weekday, let which):
            let isIt = { (date: Date) in calendar.component(.weekday, from: date) == weekday }
            switch which {
            case .coming: return first((0..<7).map { $0 * step }, where: isIt)
            case .last: return first((1...7).map { -$0 }, where: isIt)
            case .next: return calendar.dateInterval(of: .weekOfYear, for: today).flatMap { week in
                // In the week after this one, which is what it means on a Wednesday, and on a Saturday too.
                let days = calendar.dateComponents([.day], from: today, to: week.start).day ?? 0
                return first((7..<14).map { $0 + days }, where: isIt)
            }
            }
        case .date(let year, let month, let day, let weekday):
            let date: Date?
            if let year {
                date = valid(year: year, month: month, day: day, calendar: calendar)
            } else if let month {
                let thisYear = calendar.component(.year, from: today)
                date = [0, step].lazy.compactMap { valid(year: thisYear + $0, month: month, day: day, calendar: calendar) }
                    .first { looksBack ? $0 <= today : $0 >= today }
            } else {
                date = first((0..<62).map { $0 * step }) { calendar.component(.day, from: $0) == day }
            }
            guard let date, weekday.map({ calendar.component(.weekday, from: date) == $0 }) != false else { return nil }
            return date
        }
    }

    /// Nil for a day the month doesn't have, or a year nobody means.
    private static func valid(year: Int, month: Int?, day: Int, calendar: Calendar) -> Date? {
        let components = DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: year, month: month, day: day)
        guard (1900...2199).contains(year), components.isValidDate, let date = components.date else { return nil }
        return calendar.startOfDay(for: date)
    }

    /// `calendar`'s zone and week, in the calendar these names and numbers belong to.
    static func gregorian(like calendar: Calendar) -> Calendar {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        gregorian.firstWeekday = calendar.firstWeekday
        return gregorian
    }
}
