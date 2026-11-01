import Foundation

/// Dates as typed: "2026-10-31" says which day that is, and "days until 25 dec" or "days since 1 jan"
/// counts them. It runs before the calculator, which would take the first for a sum.
enum DateText {
    static func answer(_ text: String, now: Date = .now, calendar: Calendar = .current,
                       locale: Locale = .current) -> (text: String, value: String)? {
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
        if let date = isoDate(lower, calendar: calendar) {
            let full = date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                .weekday(.wide).day().month(.wide).year())
            return ("\(full) · \(relative(days(from: now, to: date, calendar: calendar)))", full)
        }
        return span(lower, now: now, calendar: calendar, locale: locale)
    }

    /// "days until 25 dec", "days to friday", "days since 1 jan 2020", "days from 2026-01-01".
    private static func span(_ lower: String, now: Date, calendar: Calendar, locale: Locale) -> (text: String, value: String)? {
        guard let groups = lower.groups(of: #"(?:how many )?days? (until|till|til|to|since|from) (.+)"#), let word = groups[0], let target = groups[1],
              // "days from 1 jan to 25 dec" has two dates, and this would only answer for the first.
              target.range(of: #"\b(?:to|until|till|and)\b"#, options: .regularExpression) == nil,
              let date = date(in: target, looksBack: word == "since" || word == "from", now: now, calendar: calendar) else { return nil }
        let count = days(from: now, to: date, calendar: calendar)
        let shown = date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.abbreviated).day().month(.abbreviated).year())
        guard count != 0 else { return ("\(shown) is today", "0") }
        let unit = abs(count) == 1 ? "day" : "days"
        return ("\(abs(count)) \(unit) \(count > 0 ? "until" : "since") \(shown)", "\(abs(count))")
    }

    /// A day named in `text`. Without a year it's the coming one, or the last one when looking back.
    private static func date(in text: String, looksBack: Bool, now: Date, calendar: Calendar) -> Date? {
        // One written that way is taken as written: the detector would roll 2026-02-30 into March.
        if text.range(of: #"^\d{4}[-/]\d{1,2}[-/]\d{1,2}$"#, options: .regularExpression) != nil { return isoDate(text, calendar: calendar) }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              var date = match.date else { return nil }
        if let typed = typedDay(in: text), typed != calendar.component(.day, from: date) { return nil }
        guard text.range(of: #"\b\d{4}\b"#, options: .regularExpression) == nil else { return date }
        // The detector sets a day to noon, so it's the day that's compared rather than the moment.
        let (day, today) = (calendar.startOfDay(for: date), calendar.startOfDay(for: now))
        if looksBack, day > today {
            let isWeekday = text.range(of: #"^(?:last |this )?(?:mon|tue|tues|wed|weds|thu|thur|thurs|fri|sat|sun)(?:[a-z]*day)?$"#, options: .regularExpression) != nil
            date = calendar.date(byAdding: isWeekday ? .weekOfYear : .year, value: -1, to: date) ?? date
        } else if !looksBack, day < today {
            date = calendar.date(byAdding: .year, value: 1, to: date) ?? date
        }
        return date
    }

    /// The day of the month typed in `text`, with a month or an ordinal to say that's what it is:
    /// "nov 31", "31 nov", "31st of november", "the 31st". The detector rolls one that doesn't exist
    /// into the next month, so this is what to hold its answer to.
    static func typedDay(in text: String) -> Int? {
        let month = #"(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?"#
        for pattern in [#"(?i)\b(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?"# + month, #"(?i)\b"# + month + #"\s+(\d{1,2})(?:st|nd|rd|th)?\b"#,
                        #"(?i)\b(\d{1,2})(?:st|nd|rd|th)\b"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { continue }
            return Int(text[range])
        }
        return nil
    }

    /// 2026-10-31 or 2026/10/31, if there is such a day in a year someone would mean. 2026-13-45 and
    /// 1500-10-20 are left to be sums. It's always the Gregorian calendar, whichever the Mac uses.
    private static func isoDate(_ text: String, calendar: Calendar) -> Date? {
        guard let parts = text.groups(of: #"(\d{4})[-/](\d{2})[-/](\d{2})"#)?.compactMap({ $0.flatMap { Int($0) } }), parts.count == 3,
              (1900...2199).contains(parts[0]) else { return nil }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let components = DateComponents(calendar: gregorian, timeZone: gregorian.timeZone, year: parts[0], month: parts[1], day: parts[2])
        return components.isValidDate ? components.date : nil
    }

    private static func days(from now: Date, to date: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
    }

    private static func relative(_ days: Int) -> String {
        switch days {
        case 0: "today"
        case 1: "tomorrow"
        case -1: "yesterday"
        case 2...: "in \(days) days"
        default: "\(-days) days ago"
        }
    }
}
