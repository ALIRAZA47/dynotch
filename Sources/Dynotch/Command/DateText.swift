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
        if let date = isoDate(text, calendar: calendar) { return date }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              var date = match.date else { return nil }
        guard text.range(of: #"\b\d{4}\b"#, options: .regularExpression) == nil else { return date }
        let today = calendar.startOfDay(for: now)
        if looksBack, date > now {
            let isWeekday = text.range(of: #"^(?:last )?(?:mon|tue|wed|thu|fri|sat|sun)"#, options: .regularExpression) != nil
            date = calendar.date(byAdding: isWeekday ? .weekOfYear : .year, value: -1, to: date) ?? date
        } else if !looksBack, date < today {
            date = calendar.date(byAdding: .year, value: 1, to: date) ?? date
        }
        return date
    }

    /// 2026-10-31 or 2026/10/31, if there is such a day. 2026-13-45 is left to be a sum.
    private static func isoDate(_ text: String, calendar: Calendar) -> Date? {
        guard let parts = text.groups(of: #"(\d{4})[-/](\d{2})[-/](\d{2})"#)?.compactMap({ $0.flatMap { Int($0) } }), parts.count == 3 else { return nil }
        let components = DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: parts[0], month: parts[1], day: parts[2])
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
