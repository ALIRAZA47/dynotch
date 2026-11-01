import Foundation

/// One of Claude's two limits.
package enum UsageLimit: String, CaseIterable {
    case fiveHour, sevenDay

    /// What Claude Code calls it in the status line's JSON.
    package var statusLineKey: String { self == .fiveHour ? "five_hour" : "seven_day" }
    /// As in "62% of your 5 hours".
    package var name: String { self == .fiveHour ? "5 hours" : "7 days" }
    /// As in "62% of 5 h".
    package var shortName: String { self == .fiveHour ? "5 h" : "7 d" }

    /// "62% of 5 h", or "5 h reset" once the number means nothing.
    package func short(percent: Int, hasReset: Bool) -> String {
        hasReset ? "\(shortName) reset" : "\(percent)% of \(shortName)"
    }
}

/// How much of a limit has been used, and when it starts over.
package struct UsageWindow: Codable, Equatable {
    /// Where the heads-up comes, and the ring turns orange.
    package static let warnsAt = 80
    /// Where the ring turns red.
    package static let nearlyOutAt = 95
    /// A limit lasts a week at most, so a reset this far from now, either way, isn't one.
    package static let furthestReset: TimeInterval = 30 * 24 * 3600

    /// Whole percent, as shown, so the ring and the heads-up can't disagree.
    package var percent: Int
    package var resetsAt: Date

    package init(percent: Int, resetsAt: Date) {
        self.percent = percent
        self.resetsAt = resetsAt
    }

    /// Nil if either number makes no sense. `resetsAt` is in epoch seconds.
    package init?(used: Double?, resetsAt: Double?, now: Date) {
        guard let percent = Self.percent(used), let resetsAt, resetsAt.isFinite else { return nil }
        let date = Date(timeIntervalSince1970: resetsAt)
        guard abs(date.timeIntervalSince(now)) <= Self.furthestReset else { return nil }
        self.init(percent: percent, resetsAt: date)
    }

    package var fraction: Double { Double(percent) / 100 }

    /// Past this, its number no longer means anything.
    package func hasReset(at now: Date) -> Bool { resetsAt <= now }

    /// 0 to 100, or nil for anything that isn't a number.
    package static func percent(_ used: Double?) -> Int? {
        guard let used, used.isFinite else { return nil }
        return Int(min(max(used, 0), 100).rounded())
    }

    /// A number from JSON. A boolean arrives as an NSNumber too, and it isn't one.
    package static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }
}

/// "now", "5m ago", "2h ago"
package func timeAgo(_ date: Date, from now: Date = .now) -> String {
    let minutes = Int(now.timeIntervalSince(date) / 60)
    if minutes < 1 { return "now" }
    return minutes < 60 ? "\(minutes)m ago" : "\(minutes / 60)h ago"
}
