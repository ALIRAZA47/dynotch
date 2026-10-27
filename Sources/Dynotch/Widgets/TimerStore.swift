import AppKit
import Combine
import SwiftUI

/// A named countdown from the Focus tab, like "Tea, 4 min".
struct Countdown: Identifiable, Equatable {
    let id: UUID
    var name: String
    var duration: TimeInterval
    /// When it ends, while it runs.
    var endDate: Date?
    /// What's left, while it's paused.
    var pausedRemaining: TimeInterval?

    var isRunning: Bool { endDate != nil }

    func remaining(at now: Date) -> TimeInterval {
        if let endDate { return max(0, endDate.timeIntervalSince(now)) }
        return pausedRemaining ?? duration
    }

    func progress(at now: Date) -> Double {
        duration > 0 ? 1 - remaining(at: now) / duration : 1
    }
}

/// A stopwatch that keeps its time across pauses.
struct Stopwatch: Equatable {
    /// When the current run started.
    var startDate: Date?
    /// Time from earlier runs.
    var banked: TimeInterval = 0

    var isRunning: Bool { startDate != nil }
    var isReset: Bool { startDate == nil && banked == 0 }

    func elapsed(at now: Date) -> TimeInterval {
        banked + (startDate.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }
}

/// Named timers started from text like "tea 4m", and a stopwatch. They live next to the
/// Pomodoro on the Focus tab; the closed notch shows the one that ends soonest.
@MainActor
final class TimerStore: ObservableObject {
    static let shared = TimerStore()

    /// Amber, so a named timer never reads as the Pomodoro.
    nonisolated static let tint = Color(red: 1.0, green: 0.72, blue: 0.26)
    nonisolated static let stopwatchTint = Color(red: 0.42, green: 0.78, blue: 1.0)

    @Published private(set) var countdowns: [Countdown] = []
    @Published private(set) var stopwatch = Stopwatch()
    /// Moves on twice a second while anything runs, so the views keep time.
    @Published private(set) var now = Date.now

    private var ticker: Timer?

    private init() {}

    /// Starts a timer from text like "tea 4m" or "laundry 45". False when there's no time in it.
    @discardableResult
    func start(_ text: String) -> Bool {
        guard let (name, duration) = TimerText.parse(text) else { return false }
        countdowns.append(Countdown(id: UUID(), name: name, duration: duration, endDate: .now.addingTimeInterval(duration)))
        refreshTicker()
        return true
    }

    func cancel(_ countdown: Countdown) {
        countdowns.removeAll { $0.id == countdown.id }
        refreshTicker()
    }

    func togglePause(_ countdown: Countdown) {
        guard let index = countdowns.firstIndex(where: { $0.id == countdown.id }) else { return }
        let now = Date.now
        if let end = countdowns[index].endDate {
            countdowns[index].pausedRemaining = max(0, end.timeIntervalSince(now))
            countdowns[index].endDate = nil
        } else {
            countdowns[index].endDate = now.addingTimeInterval(countdowns[index].pausedRemaining ?? countdowns[index].duration)
            countdowns[index].pausedRemaining = nil
        }
        refreshTicker()
    }

    func toggleStopwatch() {
        if let start = stopwatch.startDate {
            stopwatch.banked += max(0, Date.now.timeIntervalSince(start))
            stopwatch.startDate = nil
        } else {
            stopwatch.startDate = .now
        }
        refreshTicker()
    }

    func resetStopwatch() {
        stopwatch = Stopwatch()
        refreshTicker()
    }

    // MARK: Private

    private func refreshTicker() {
        now = .now
        let running = stopwatch.isRunning || countdowns.contains(where: \.isRunning)
        if running, ticker == nil {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
        } else if !running {
            ticker?.invalidate()
            ticker = nil
        }
    }

    private func tick() {
        now = .now
        let finished = countdowns.filter { $0.endDate.map { $0 <= now } ?? false }
        guard !finished.isEmpty else { return }
        countdowns.removeAll { countdown in finished.contains { $0.id == countdown.id } }
        refreshTicker()
        announce(finished)
    }

    /// A notice and a sound when timers reach zero.
    private func announce(_ finished: [Countdown]) {
        if AppSettings.shared.timerSound { NSSound(named: "Hero")?.play() }
        let detail = finished.count == 1
            ? "\(finished[0].name) · \(TimerText.describe(finished[0].duration))"
            : finished.map(\.name).joined(separator: ", ")
        LiveActivityCenter.shared.post(LiveNotice(key: "countdown", symbol: "bell.fill", tint: Self.tint, text: "Done",
                                                  detail: detail), for: 8)
    }

    // MARK: Snapshots

    /// The same timers every time, as of `now`.
    func loadSample(at now: Date) {
        func id(_ number: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))! }
        self.now = now
        countdowns = [
            Countdown(id: id(1), name: "Tea", duration: 240, endDate: now.addingTimeInterval(221)),
            Countdown(id: id(2), name: "Laundry", duration: 2700, endDate: now.addingTimeInterval(2652)),
            Countdown(id: id(3), name: "Bread dough", duration: 3600, pausedRemaining: 1500),
        ]
        stopwatch = Stopwatch(startDate: now.addingTimeInterval(-754))
    }

    func clearSample() {
        countdowns = []
        stopwatch = Stopwatch()
    }
}
