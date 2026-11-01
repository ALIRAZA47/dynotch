import SwiftUI

/// One of Claude's two limits.
enum UsageLimit: String, CaseIterable {
    case fiveHour, sevenDay

    /// What Claude Code calls it in the status line's JSON.
    var statusLineKey: String { self == .fiveHour ? "five_hour" : "seven_day" }
    /// As in "62% of your 5 hours".
    var name: String { self == .fiveHour ? "5 hours" : "7 days" }
    /// As in "62% of 5 h".
    var shortName: String { self == .fiveHour ? "5 h" : "7 d" }

    /// "62% of 5 h", or "5 h reset" once the number means nothing.
    func short(percent: Int, hasReset: Bool) -> String {
        hasReset ? "\(shortName) reset" : "\(percent)% of \(shortName)"
    }
}

/// How much of a limit has been used, and when it starts over.
struct UsageWindow: Codable, Equatable {
    /// Where the heads-up comes, and the ring turns orange.
    static let warnsAt = 80
    /// Where the ring turns red.
    static let nearlyOutAt = 95
    /// A limit lasts a week at most, so a reset this far from now, either way, isn't one.
    static let furthestReset: TimeInterval = 30 * 24 * 3600

    /// Whole percent, as shown, so the ring and the heads-up can't disagree.
    var percent: Int
    var resetsAt: Date

    init(percent: Int, resetsAt: Date) {
        self.percent = percent
        self.resetsAt = resetsAt
    }

    /// Nil if either number makes no sense. `resetsAt` is in epoch seconds.
    init?(used: Double?, resetsAt: Double?, now: Date) {
        guard let percent = Self.percent(used), let resetsAt, resetsAt.isFinite else { return nil }
        let date = Date(timeIntervalSince1970: resetsAt)
        guard abs(date.timeIntervalSince(now)) <= Self.furthestReset else { return nil }
        self.init(percent: percent, resetsAt: date)
    }

    var fraction: Double { Double(percent) / 100 }

    /// Past this, its number no longer means anything.
    func hasReset(at now: Date) -> Bool { resetsAt <= now }

    /// `normal`, warming up toward the limit.
    func tint(_ normal: Color) -> Color {
        percent >= Self.nearlyOutAt ? .red : percent >= Self.warnsAt ? .orange : normal
    }

    /// 0 to 100, or nil for anything that isn't a number.
    static func percent(_ used: Double?) -> Int? {
        guard let used, used.isFinite else { return nil }
        return Int(min(max(used, 0), 100).rounded())
    }

    /// A number from JSON. A boolean arrives as an NSNumber too, and it isn't one.
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }
}

/// The last numbers to arrive. Either window can be missing: a plan may have only one, and Claude
/// Code leaves one out once it has reset.
struct UsageNumbers: Codable, Equatable {
    var fiveHour: UsageWindow?
    var sevenDay: UsageWindow?
    var receivedAt: Date

    subscript(limit: UsageLimit) -> UsageWindow? {
        get { limit == .fiveHour ? fiveHour : sevenDay }
        set {
            if limit == .fiveHour {
                fiveHour = newValue
            } else {
                sevenDay = newValue
            }
        }
    }

    /// The limit to show first: the fuller of those still running, the five hours if they're level.
    func main(at now: Date) -> UsageLimit? {
        UsageLimit.allCases
            .filter { self[$0]?.hasReset(at: now) == false }
            .max { (self[$0]?.percent ?? 0) < (self[$1]?.percent ?? 0) }
    }

    /// "62% of your 5 hours", or what has reset.
    func title(at now: Date) -> String {
        if let limit = main(at: now), let window = self[limit] { return "\(window.percent)% of your \(limit.name)" }
        let known = UsageLimit.allCases.filter { self[$0] != nil }
        return known.count == 1 ? "Your \(known[0].name) have reset" : "Your limits have reset"
    }

    /// "Resets in 1 h 14 min · 7 days 38%": when the main one starts over, and how the other stands.
    func subtitle(at now: Date) -> String {
        guard let limit = main(at: now), let window = self[limit] else { return "New numbers come with your next message" }
        var parts = ["Resets in " + Format.timeLeft(to: window.resetsAt, from: now)]
        for other in UsageLimit.allCases where other != limit {
            guard let window = self[other] else { continue }
            parts.append(window.hasReset(at: now) ? "\(other.name) reset" : "\(other.name) \(window.percent)%")
        }
        return parts.joined(separator: " · ")
    }

    /// "Updated 3m ago". They're only as fresh as the last active session.
    func age(at now: Date) -> String {
        let days = Int(now.timeIntervalSince(receivedAt) / (24 * 3600))
        if days >= 2 { return "Updated \(days)d ago" }
        let ago = Format.ago(receivedAt, from: now)
        return ago == "now" ? "Updated just now" : "Updated \(ago)"
    }
}

extension Format {
    /// "14 min", "1 h 14 min", "3 days 4 h"
    static func timeLeft(to date: Date, from now: Date) -> String {
        let minutes = max(Int((date.timeIntervalSince(now) / 60).rounded(.up)), 1)
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        if hours < 24 { return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min" }
        let days = hours / 24, leftOver = hours % 24
        let whole = days == 1 ? "1 day" : "\(days) days"
        return leftOver == 0 ? whole : "\(whole) \(leftOver) h"
    }
}

/// How much of Claude's limits have been used, as the last active session reported it. The numbers
/// arrive with each message and nothing is polled, so a limit that resets in between is worked out
/// by whoever's looking.
@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    /// With the same numbers arriving, the age moves no more often than this: it's all there is to redraw.
    static let ageStep: TimeInterval = 30
    /// How long the heads-up stays.
    static let warningSeconds: TimeInterval = 6

    private static let numbersKey = "usageNumbers"
    private static let warnedKey = "usageWarnedFor"

    /// Nil until a session has said anything. They stay once a limit resets, to say that it has.
    @Published private(set) var numbers: UsageNumbers?

    /// The reset each limit last warned about, by name. Until it has gone by, it's the same period.
    private var warnedFor: [String: Date]
    private let post: @MainActor (LiveNotice, TimeInterval) -> Void

    init(post: @escaping @MainActor (LiveNotice, TimeInterval) -> Void = { LiveActivityCenter.shared.post($0, for: $1) }) {
        self.post = post
        let defaults = UserDefaults.dynotch
        numbers = defaults.data(forKey: Self.numbersKey).flatMap { try? JSONDecoder().decode(UsageNumbers.self, from: $0) }
        warnedFor = defaults.dictionary(forKey: Self.warnedKey) as? [String: Date] ?? [:]
    }

    func start(on router: SocketRouter? = nil) {
        let router = router ?? .shared
        router.handle("usage") { [weak self] request, connection in
            guard let self else { return }
            connection.reply(self.apply(request))
        }
        router.reportsStatus("usage") { [weak self] in self?.statusReport(at: .now) ?? [:] }
    }

    /// Carries out a `usage` request, and says how it went. A window that's missing or makes no sense
    /// stays as it was.
    func apply(_ request: SocketRequest, now: Date = .now) -> [String: Any] {
        var next = numbers ?? UsageNumbers(receivedAt: now)
        var arrived: [UsageLimit] = []
        for limit in UsageLimit.allCases {
            let fields = request.fields[limit.rawValue] as? [String: Any]
            guard let window = UsageWindow(used: UsageWindow.number(fields?["used"]),
                                           resetsAt: UsageWindow.number(fields?["resetsAt"]), now: now) else { continue }
            next[limit] = window
            arrived.append(limit)
        }
        guard !arrived.isEmpty else { return ["ok": false, "error": "No usage numbers in that"] }
        keep(next, at: now)
        warn(about: arrived, in: next, now: now)
        return ["ok": true]
    }

    /// What `dynotch status` says. It's there with the switch off too, since the numbers still arrive.
    func statusReport(at now: Date) -> [String: Any] {
        func report(_ window: UsageWindow?) -> Any {
            guard let window else { return NSNull() }
            return ["percent": window.percent, "resetsAt": Int(window.resetsAt.timeIntervalSince1970),
                    "hasReset": window.hasReset(at: now)]
        }
        return ["fiveHour": report(numbers?.fiveHour), "sevenDay": report(numbers?.sevenDay),
                "secondsOld": numbers.map { Int(now.timeIntervalSince($0.receivedAt)) } ?? NSNull()]
    }

    /// In memory only, so a snapshot run saves nothing.
    func loadSample(fiveHour: UsageWindow?, sevenDay: UsageWindow?, receivedAt: Date) {
        numbers = UsageNumbers(fiveHour: fiveHour, sevenDay: sevenDay, receivedAt: receivedAt)
    }

    /// Back to nothing, between snapshot scenes.
    func clearSample() {
        numbers = nil
    }

    /// Publishes and saves what's new. Numbers that only repeat just move the age, now and then.
    private func keep(_ next: UsageNumbers, at now: Date) {
        if next == numbers, let numbers, now.timeIntervalSince(numbers.receivedAt) < Self.ageStep { return }
        var next = next
        next.receivedAt = now
        numbers = next
        if let data = try? JSONEncoder().encode(next) { UserDefaults.dynotch.set(data, forKey: Self.numbersKey) }
    }

    /// One notice for whatever has just reached the line: a notice replaces another with the same key,
    /// so two limits reaching it at once would lose one. It says no times, since it may have to wait.
    private func warn(about limits: [UsageLimit], in numbers: UsageNumbers, now: Date) {
        guard AppSettings.shared.liveUsage else { return }
        let due = limits.filter { limit in
            guard let window = numbers[limit], window.percent >= UsageWindow.warnsAt, !window.hasReset(at: now) else { return false }
            return warnedFor[limit.rawValue].map { $0 <= now } ?? true
        }
        guard !due.isEmpty else { return }
        for limit in due { warnedFor[limit.rawValue] = numbers[limit]?.resetsAt }
        UserDefaults.dynotch.set(warnedFor, forKey: Self.warnedKey)
        let fullest = due.compactMap { numbers[$0] }.max { $0.percent < $1.percent }
        let detail = due.compactMap { limit in numbers[limit].map { "\($0.percent)% of your \(limit.name)" } }
        post(LiveNotice(key: "usage", symbol: LiveActivityKind.usage.symbol, tint: fullest?.tint(.orange) ?? .orange,
                        text: "Claude usage", detail: detail.joined(separator: " · "),
                        actions: [NoticeAction(title: "Show", kind: .showUsage)], timing: .waits, recall: .whole),
             Self.warningSeconds)
    }
}
