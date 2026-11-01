import Foundation

/// Somewhere on the clock: a city, or a time zone's initials.
struct WorldPlace: Equatable {
    let name: String
    let zone: TimeZone
    /// Typed as initials, like PST, rather than as a place.
    var isInitials = false
}

/// What the time is somewhere else, worked out on the Mac: "5pm pst in lahore", "3:30pm london to
/// tokyo", "noon in nyc", "time in tokyo", "tokyo time". Initials mean that zone's clock rather than
/// a fixed offset, so `pst` in summer is read as PDT, and the answer shows the offset it used.
enum WorldTime {
    /// A city or initials, in any case. Every city macOS names a zone after is here, with `cities` for
    /// the ones it doesn't.
    static func place(_ text: String) -> WorldPlace? {
        let key = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        if let initials = initials[key], let zone = TimeZone(identifier: initials) {
            return WorldPlace(name: key.uppercased(), zone: zone, isInitials: true)
        }
        guard let city = places[key], let zone = TimeZone(identifier: city.zone) else { return nil }
        return WorldPlace(name: city.name, zone: zone)
    }

    /// Initials on their own, in any case: `place` also answers to cities.
    static func initials(_ text: String) -> WorldPlace? {
        place(text).flatMap { $0.isInitials ? $0 : nil }
    }

    /// The time at `place`, with its day when that isn't the day it is here.
    static func clock(at place: WorldPlace, on date: Date = .now, here: TimeZone = .current,
                      locale: Locale = .current) -> (time: String, day: String?) {
        (time(date, in: place.zone, locale: locale), day(date, in: place.zone, apartFrom: here, locale: locale))
    }

    static func answer(_ text: String, now: Date = .now, here: TimeZone = .current,
                       locale: Locale = .current) -> (text: String, value: String)? {
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
        if let name = lower.groups(of: #"(.+) time"#)?[0], let place = place(name) {
            return current(in: place, now: now, here: here, locale: locale)
        }
        guard let groups = lower.groups(of: #"(.+?)\s+(in|to)\s+(.+)"#), let left = groups[0], let right = groups[2],
              let target = place(right) else { return nil }
        // "time to eat" isn't East Africa.
        if ["time", "now", "the time"].contains(left) {
            return groups[1] == "in" ? current(in: target, now: now, here: here, locale: locale) : nil
        }
        guard let wall = wallClock(left) else { return nil }
        var source: WorldPlace?
        if let name = wall.place {
            guard let place = place(name) else { return nil }
            source = place
        }
        let zone = source?.zone ?? here
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var day = calendar.dateComponents([.year, .month, .day], from: now)
        day.hour = wall.hour
        day.minute = wall.minute
        guard let date = calendar.date(from: day) else { return nil }

        let from = time(date, in: zone, locale: locale) + " " + (source.map { label($0, at: date) } ?? "here")
        let to = time(date, in: target.zone, locale: locale)
        let shift = Self.day(date, in: target.zone, apartFrom: zone, locale: locale)
        let shown = [to, shift].compactMap { $0 }.joined(separator: " ")
        return ("\(from) = \(shown) \(label(target, at: date))", shown)
    }

    // MARK: Pieces

    private static func current(in place: WorldPlace, now: Date, here: TimeZone, locale: Locale) -> (text: String, value: String) {
        let clock = clock(at: place, on: now, here: here, locale: locale)
        let shown = [clock.time, clock.day].compactMap { $0 }.joined(separator: " ")
        return ("\(shown) \(label(place, at: now))", shown)
    }

    /// "5pm", "5:30 pm", "17:00", "noon", and what follows it, which should be a place. A bare number
    /// isn't a time: that's a timer, or a unit.
    private static func wallClock(_ text: String) -> (hour: Int, minute: Int, place: String?)? {
        if let groups = text.groups(of: #"(noon|midnight)(?:\s+(.+))?"#) {
            return (groups[0] == "noon" ? 12 : 0, 0, groups[1])
        }
        guard let groups = text.groups(of: #"(\d{1,2})(?:[:.](\d{2}))?\s*(?:([ap])m?\b)?(?:\s+(.+))?"#),
              let typed = groups[0].flatMap({ Int($0) }) else { return nil }
        let minute = groups[1].flatMap { Int($0) } ?? 0
        guard minute < 60, groups[1] != nil || groups[2] != nil else { return nil }
        guard let meridiem = groups[2] else { return typed < 24 ? (typed, minute, groups[3]) : nil }
        guard (1...12).contains(typed) else { return nil }
        return (typed % 12 + (meridiem == "p" ? 12 : 0), minute, groups[3])
    }

    private static func label(_ place: WorldPlace, at date: Date) -> String {
        guard place.isInitials else { return "in \(place.name)" }
        // A zone that changes its clocks says which side of the change it's on, as PDT or as GMT+2,
        // since what was typed may be the other side. For one that doesn't, what was typed says more.
        guard place.zone.nextDaylightSavingTimeTransition(after: date) != nil else { return place.name }
        return place.zone.abbreviation(for: date) ?? place.name
    }

    private static func time(_ date: Date, in zone: TimeZone, locale: Locale) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: zone))
    }

    /// The weekday in `zone`, if it isn't the same day in `other`.
    private static func day(_ date: Date, in zone: TimeZone, apartFrom other: TimeZone, locale: Locale) -> String? {
        func calendarDay(_ zone: TimeZone) -> DateComponents {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            return calendar.dateComponents([.year, .month, .day], from: date)
        }
        guard calendarDay(zone) != calendarDay(other) else { return nil }
        return date.formatted(Date.FormatStyle(locale: locale, timeZone: zone).weekday(.abbreviated))
    }

    // MARK: Places

    /// Initials to a zone. macOS's own list, with what it leaves out.
    private static let initials: [String: String] = {
        var table = Dictionary(uniqueKeysWithValues: TimeZone.abbreviationDictionary.map { ($0.key.lowercased(), $0.value) })
        table.merge([
            "et": "America/New_York", "ct": "America/Chicago", "mt": "America/Denver", "pt": "America/Los_Angeles",
            "aest": "Australia/Sydney", "aedt": "Australia/Sydney", "acst": "Australia/Adelaide", "acdt": "Australia/Adelaide",
            "awst": "Australia/Perth", "wib": "Asia/Jakarta", "wita": "Asia/Makassar", "nzt": "Pacific/Auckland",
            "sast": "Africa/Johannesburg", "npt": "Asia/Kathmandu", "aft": "Asia/Kabul", "azt": "Asia/Baku",
        ]) { _, new in new }
        return table
    }()

    /// Places that aren't in a zone's name, and a few short ways of saying the ones that are.
    static let cities: [(zone: String, names: [String])] = [
        ("Asia/Karachi", ["Lahore", "Islamabad", "Rawalpindi", "Faisalabad", "Peshawar", "Multan", "Quetta", "Pakistan"]),
        ("Asia/Kolkata", ["Delhi", "New Delhi", "Mumbai", "Bangalore", "Bengaluru", "Hyderabad", "Chennai", "Pune", "India"]),
        ("America/New_York", ["NYC", "New York City", "Boston", "Washington", "DC", "Miami", "Atlanta", "Philadelphia"]),
        ("America/Chicago", ["Dallas", "Houston", "Austin"]),
        ("America/Denver", ["Salt Lake City"]),
        ("America/Los_Angeles", ["SF", "San Francisco", "LA", "Seattle", "San Diego", "Portland", "Las Vegas"]),
        ("America/Toronto", ["Montreal", "Ottawa"]),
        ("America/Edmonton", ["Calgary"]),
        ("America/Mexico_City", ["Mexico"]),
        ("America/Sao_Paulo", ["Rio de Janeiro", "Rio", "Brazil"]),
        ("Europe/London", ["UK", "Manchester", "Edinburgh"]),
        ("Europe/Paris", ["France"]),
        ("Europe/Berlin", ["Germany", "Munich", "Frankfurt", "Hamburg"]),
        ("Europe/Madrid", ["Spain", "Barcelona"]),
        ("Europe/Rome", ["Italy", "Milan"]),
        ("Europe/Amsterdam", ["Netherlands"]),
        ("Europe/Zurich", ["Geneva", "Switzerland"]),
        ("Europe/Kyiv", ["Kiev", "Ukraine"]),
        ("Europe/Istanbul", ["Turkey", "Ankara"]),
        ("Asia/Dubai", ["Abu Dhabi", "UAE"]),
        ("Asia/Riyadh", ["Jeddah", "Mecca", "Medina", "Saudi Arabia"]),
        ("Asia/Qatar", ["Doha"]),
        ("Asia/Jerusalem", ["Tel Aviv", "Israel"]),
        ("Africa/Johannesburg", ["Cape Town", "South Africa"]),
        ("Asia/Tokyo", ["Osaka", "Kyoto", "Japan"]),
        ("Asia/Seoul", ["Korea", "South Korea"]),
        ("Asia/Shanghai", ["Beijing", "Shenzhen", "Guangzhou", "China"]),
        ("Asia/Ho_Chi_Minh", ["Saigon", "Hanoi", "Vietnam"]),
        ("Australia/Sydney", ["Canberra"]),
        ("Pacific/Auckland", ["Wellington", "New Zealand"]),
    ]

    /// In lowercase, the name to show and the zone. Every city macOS names a zone after, then `cities`.
    private static let places: [String: (name: String, zone: String)] = {
        var table: [String: (name: String, zone: String)] = [:]
        for zone in TimeZone.knownTimeZoneIdentifiers {
            guard zone.contains("/"), let city = zone.split(separator: "/").last else { continue }
            let name = city.replacingOccurrences(of: "_", with: " ")
            table[name.lowercased()] = (name, zone)
        }
        for (zone, names) in cities {
            for name in names { table[name.lowercased()] = (name, zone) }
        }
        return table
    }()
}
