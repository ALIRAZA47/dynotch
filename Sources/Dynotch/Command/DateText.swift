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

    /// "days until 25 dec", "days to friday", "days since 1 jan 2020", "days from 2026-01-01". What
    /// follows has to be one day and nothing else: "days from 1 jan to 25 dec" has two.
    private static func span(_ lower: String, now: Date, calendar: Calendar, locale: Locale) -> (text: String, value: String)? {
        guard let groups = lower.groups(of: #"(?:how many )?days? (until|till|til|to|since|from) (.+?)\??"#), let word = groups[0], let target = groups[1],
              let found = DayText.find(in: target).first, found.range == target.startIndex..<target.endIndex,
              let date = DayText.day(found.kind, now: now, calendar: DayText.gregorian(like: calendar),
                                     looksBack: word == "since" || word == "from") else { return nil }
        let count = days(from: now, to: date, calendar: calendar)
        let shown = date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.abbreviated).day().month(.abbreviated).year())
        guard count != 0 else { return ("\(shown) is today", "0") }
        let unit = abs(count) == 1 ? "day" : "days"
        return ("\(abs(count)) \(unit) \(count > 0 ? "until" : "since") \(shown)", "\(abs(count))")
    }

    /// 2026-10-31 or 2026/10/31, if there is such a day in a year someone would mean. 2026-13-45 and
    /// 1500-10-20 are left to be sums. It's always the Gregorian calendar, whichever the Mac uses.
    private static func isoDate(_ text: String, calendar: Calendar) -> Date? {
        guard let parts = text.groups(of: #"(\d{4})[-/](\d{2})[-/](\d{2})"#)?.compactMap({ $0.flatMap { Int($0) } }), parts.count == 3 else { return nil }
        return DayText.day(.date(year: parts[0], month: parts[1], day: parts[2], weekday: nil), now: .distantPast, calendar: DayText.gregorian(like: calendar))
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
