import Foundation

/// The closed notch's notices: the one showing, those waiting their turn, and those held back while
/// the Mac is quiet. It has no clock of its own. `LiveActivityCenter` tells it the time and wakes it
/// at `nextChange`, which keeps these rules easy to follow and to test.
struct NoticeQueue {
    struct Entry: Equatable {
        var notice: LiveNotice
        var duration: TimeInterval
    }

    /// The least a notice is on screen before one behind it takes over.
    static let shortestTurn: TimeInterval = 2
    /// How long a notice stays while others wait behind it.
    static let busyTurn: TimeInterval = 3
    /// How long a notice lingers once the pointer leaves it.
    static let afterHold: TimeInterval = 1.2
    /// A pointer can't hold a notice for longer, in case its display went away mid-glance.
    static let longestHold: TimeInterval = 120
    static let mostWaiting = 6
    static let mostHeld = 30
    /// With more than this held when the Mac stops being quiet, they come out as one notice.
    static let mostReplayed = 2

    private(set) var showing: Entry?
    /// A volume or brightness meter, on top of the notice for a moment.
    private(set) var meter: LiveNotice?
    private(set) var waiting: [Entry] = []
    private(set) var held: [Entry] = []

    private var shownAt = Date.distantPast
    /// When the notice showing ends. Nil while its clock is stopped.
    private var endsAt: Date?
    /// What's left of its time while the clock is stopped.
    private var timeLeft: TimeInterval = 0
    private var meterEndsAt: Date?
    private var holdEndsAt: Date?

    /// What the notch shows now.
    var visible: LiveNotice? { meter ?? showing?.notice }

    /// When something next has to happen.
    var nextChange: Date? { [endsAt, meterEndsAt, holdEndsAt].compactMap { $0 }.min() }

    private var isClockStopped: Bool { meter != nil || holdEndsAt != nil }

    // MARK: Posting

    mutating func post(_ entry: Entry, isQuiet: Bool, now: Date) {
        if isQuiet, entry.notice.timing != .always {
            if entry.notice.timing == .waits { hold(entry) }
        } else if showing == nil {
            show(entry, now: now)
        } else if showing?.notice.key == entry.notice.key {
            // The same key updates in place. Its time starts over, unless that would keep others waiting.
            if waiting.isEmpty {
                show(entry, now: now)
            } else {
                showing = entry
            }
        } else {
            wait(entry, now: now)
        }
    }

    mutating func showMeter(_ notice: LiveNotice, for duration: TimeInterval, now: Date) {
        stopClock(now: now)
        meter = notice
        meterEndsAt = now.addingTimeInterval(duration)
    }

    /// Takes the notice showing off the notch, for the next one.
    mutating func dismiss(now: Date) {
        next(now: now)
    }

    // MARK: Time

    mutating func tick(now: Date) {
        if let end = meterEndsAt, end <= now {
            meter = nil
            meterEndsAt = nil
            startClock(now: now)
        }
        if let end = holdEndsAt, end <= now { setHeldByPointer(false, now: now) }
        if let end = endsAt, end <= now { next(now: now) }
    }

    /// The pointer rests on the notice in the glance: it stays until the pointer leaves.
    mutating func setHeldByPointer(_ isHeld: Bool, now: Date) {
        if isHeld {
            stopClock(now: now)
            holdEndsAt = now.addingTimeInterval(Self.longestHold)
        } else if holdEndsAt != nil {
            holdEndsAt = nil
            timeLeft = min(timeLeft, Self.afterHold)
            startClock(now: now)
        }
    }

    // MARK: Quiet

    /// A call or a presentation has started: what can wait goes aside, and what would go stale goes.
    mutating func goQuiet(now: Date) {
        for entry in [showing].compactMap({ $0 }) + waiting where entry.notice.timing == .waits { hold(entry) }
        waiting.removeAll { $0.notice.timing != .always }
        if let showing, showing.notice.timing != .always { next(now: now) }
    }

    /// The Mac is free again: what was held comes out, one by one if it's little, as one notice if not.
    /// `holdingBack` names what shouldn't show after all, as what's true now may not be what was true then.
    mutating func endQuiet(now: Date, holdingBack keys: Set<String> = []) {
        let released = held.filter { !keys.contains($0.notice.key) }
        held = []
        if released.count > Self.mostReplayed {
            post(Entry(notice: Self.summary(of: released.map(\.notice)), duration: 6), isQuiet: false, now: now)
        } else {
            released.forEach { post($0, isQuiet: false, now: now) }
        }
    }

    /// One notice for many: how many there were, and where they came from.
    static func summary(of notices: [LiveNotice]) -> LiveNotice {
        var names: [String] = []
        for notice in notices {
            guard let name = notice.sourceName, !names.contains(name) else { continue }
            names.append(name)
        }
        let listed = names.prefix(3).joined(separator: ", ")
        return LiveNotice(key: "held", symbol: "bell.badge.fill", tint: .white, text: "\(notices.count) new",
                          detail: listed.isEmpty ? "These waited for you" : "Waited for you: \(listed)",
                          actions: [NoticeAction(title: "See Them", kind: .showRecent)])
    }

    // MARK: Private

    private mutating func show(_ entry: Entry, now: Date) {
        showing = entry
        shownAt = now
        let turn = waiting.isEmpty ? entry.duration : min(entry.duration, Self.busyTurn)
        if isClockStopped {
            timeLeft = turn
            endsAt = nil
        } else {
            endsAt = now.addingTimeInterval(turn)
        }
    }

    private mutating func wait(_ entry: Entry, now: Date) {
        if let index = waiting.firstIndex(where: { $0.notice.key == entry.notice.key }) {
            waiting[index] = entry
        } else if entry.notice.timing == .always {
            // The answer to something you just did, or something that can't wait, goes next.
            waiting.insert(entry, at: 0)
        } else {
            waiting.append(entry)
        }
        if waiting.count > Self.mostWaiting {
            // The oldest that can wait goes, never one that can't.
            waiting.remove(at: waiting.firstIndex { $0.notice.timing != .always } ?? waiting.count - 1)
        }
        // The notice showing makes way once it's had a moment.
        let latest = max(now, shownAt.addingTimeInterval(Self.shortestTurn))
        if let end = endsAt {
            endsAt = min(end, latest)
        } else {
            timeLeft = min(timeLeft, Self.shortestTurn)
        }
    }

    private mutating func hold(_ entry: Entry) {
        if let index = held.firstIndex(where: { $0.notice.key == entry.notice.key }) {
            held[index] = entry
        } else {
            held.append(entry)
        }
        if held.count > Self.mostHeld { held.removeFirst(held.count - Self.mostHeld) }
    }

    private mutating func next(now: Date) {
        showing = nil
        endsAt = nil
        timeLeft = 0
        if !waiting.isEmpty { show(waiting.removeFirst(), now: now) }
    }

    private mutating func stopClock(now: Date) {
        guard let end = endsAt else { return }
        timeLeft = max(end.timeIntervalSince(now), 0)
        endsAt = nil
    }

    private mutating func startClock(now: Date) {
        guard showing != nil, !isClockStopped else { return }
        endsAt = now.addingTimeInterval(max(timeLeft, 0.8))
    }
}
