import SwiftUI

/// Something a script is doing, told to the notch with `dynotch progress`. Each script has its own
/// key, so two at once no longer overwrite each other.
struct ScriptActivity: Identifiable, Equatable {
    static let defaultSymbol = "terminal.fill"

    let key: String
    /// Nil until the script gives a number.
    var percent: Int?
    var detail: String?
    var symbol = ScriptActivity.defaultSymbol
    var tint: Color?

    var id: String { key }
    var fraction: Double? { percent.map { Double($0) / 100 } }
    var percentText: String? { percent.map { "\($0)%" } }
    /// A script picked this symbol, so it needs the badge. The terminal is a mark in itself.
    var needsBadge: Bool { symbol != Self.defaultSymbol }
}

/// What scripts are doing right now. An activity lasts while its script keeps talking: one that goes
/// quiet for its `quietAfter` is taken down and says so, since it may have died halfway.
@MainActor
final class ScriptActivityStore: ObservableObject {
    enum Outcome: String {
        case done, failed
    }

    static let shared = ScriptActivityStore()

    static let mostActivities = 8
    static let longestKey = 32
    static let longestDetail = 140
    static let quietAfter: TimeInterval = 120
    static let longestQuiet: TimeInterval = 3600
    static let shortestQuiet: TimeInterval = 5

    /// What's running, oldest first, so the one on show stays put while another comes and goes.
    @Published private(set) var activities: [ScriptActivity] = []

    /// The times stay out of `ScriptActivity`, so a script that only says it's alive redraws nothing.
    private var startedAt: [String: Date] = [:]
    private var expiresAt: [String: Date] = [:]
    private var clock: Task<Void, Never>?
    private let post: @MainActor (LiveNotice, TimeInterval) -> Void

    init(post: @escaping @MainActor (LiveNotice, TimeInterval) -> Void = { LiveActivityCenter.shared.post($0, for: $1) }) {
        self.post = post
    }

    func start(on router: SocketRouter? = nil) {
        let router = router ?? .shared
        router.handle("progress") { [weak self] request, connection in
            guard let self else { return }
            connection.reply(self.apply(request))
        }
        router.reportsStatus("scripts") { [weak self] in self?.statusReport(at: .now) ?? [] }
    }

    /// Carries out a `progress` request, and says how it went.
    func apply(_ request: SocketRequest, now: Date = .now) -> [String: Any] {
        guard let key = Self.cleaned(request.string("key"), limit: Self.longestKey) else {
            return ["ok": false, "error": "A progress needs a name"]
        }
        let detail = Self.cleaned(request.string("detail"), limit: Self.longestDetail)
        switch request.string("state") {
        case "done":
            finish(key, as: .done, detail: detail, button: Self.button(in: request))
        case "failed":
            finish(key, as: .failed, detail: detail, button: Self.button(in: request))
        case "clear":
            remove(key)
        default:
            let symbol = request.string("symbol").flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil ? nil : $0 }
            guard update(key, percent: request.number("percent"), detail: detail, symbol: symbol,
                         tint: URLCommands.color(named: request.string("tint")),
                         quietAfter: request.number("quietAfter"), now: now) else {
                return ["ok": false, "error": "\(Self.mostActivities) progress lines are on already"]
            }
        }
        return ["ok": true]
    }

    /// Starts or updates an activity. Anything left out stays as it was. False if there's no room for a new one.
    @discardableResult
    func update(_ key: String, percent: Double?, detail: String? = nil, symbol: String? = nil, tint: Color? = nil,
                quietAfter: Double? = nil, now: Date = .now) -> Bool {
        let index = activities.firstIndex { $0.key == key }
        guard index != nil || activities.count < Self.mostActivities else { return false }
        var activity = index.map { activities[$0] } ?? ScriptActivity(key: key)
        if let percent, percent.isFinite { activity.percent = Int(min(max(percent, 0), 100).rounded()) }
        if let detail { activity.detail = detail }
        if let symbol { activity.symbol = symbol }
        if let tint { activity.tint = tint }
        if let index {
            if activities[index] != activity { activities[index] = activity }
        } else {
            activities.append(activity)
            startedAt[key] = now
        }
        let asked = quietAfter.flatMap { $0.isFinite ? $0 : nil }
        let patience = min(max(asked ?? Self.quietAfter, Self.shortestQuiet), Self.longestQuiet)
        expiresAt[key] = now.addingTimeInterval(patience)
        wakeForNext()
        return true
    }

    func finish(_ key: String, as outcome: Outcome, detail: String? = nil, button: NoticeAction? = nil) {
        remove(key)
        guard AppSettings.shared.liveScripts else { return }
        let failed = outcome == .failed
        post(LiveNotice(key: "script.\(key)", symbol: failed ? "xmark.octagon.fill" : "checkmark.circle.fill",
                        tint: failed ? .red : .green, text: failed ? "Failed" : "Done",
                        detail: detail.map { "\(key) · \($0)" } ?? key, fromScript: true,
                        actions: button.map { [$0] } ?? [], timing: .waits, recall: .whole), failed ? 6 : 4)
    }

    /// Takes down whatever has gone quiet by `now`.
    func expire(now: Date = .now) {
        for key in expiresAt.filter({ $0.value <= now }).keys.sorted() {
            remove(key)
            guard AppSettings.shared.liveScripts else { continue }
            post(LiveNotice(key: "script.\(key)", symbol: "questionmark.circle.fill", tint: .gray, text: "Went quiet",
                            detail: key, fromScript: true, timing: .waits, recall: .whole), 4)
        }
        wakeForNext()
    }

    /// What `dynotch status` says about each.
    func statusReport(at now: Date) -> [[String: Any]] {
        activities.map { activity in
            var report: [String: Any] = ["key": activity.key]
            report["percent"] = activity.percent ?? NSNull()
            report["detail"] = activity.detail ?? NSNull()
            report["secondsRunning"] = startedAt[activity.key].map { Int(now.timeIntervalSince($0)) }
            report["secondsLeft"] = expiresAt[activity.key].map { Int(max($0.timeIntervalSince(now), 0)) }
            return report
        }
    }

    func loadSample(_ activities: [ScriptActivity]) {
        self.activities = activities
    }

    private func remove(_ key: String) {
        activities.removeAll { $0.key == key }
        startedAt[key] = nil
        expiresAt[key] = nil
        wakeForNext()
    }

    /// One wake at the next expiry, not a poll: it does nothing until then, and nothing with no script running.
    private func wakeForNext() {
        clock?.cancel()
        clock = nil
        guard let next = expiresAt.values.min() else { return }
        clock = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(next.timeIntervalSinceNow, 0.01)))
            guard !Task.isCancelled else { return }
            self?.expire()
        }
    }

    private static func button(in request: SocketRequest) -> NoticeAction? {
        URLCommands.button(title: request.string("button"), url: request.string("url"))
    }

    /// Script text is for one line of the notch: no control characters, nothing past `limit`, and nil if nothing's left.
    static func cleaned(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let printable = String(String.UnicodeScalarView(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        let trimmed = String(printable.trimmingCharacters(in: .whitespaces).prefix(limit))
        return trimmed.isEmpty ? nil : trimmed
    }
}
