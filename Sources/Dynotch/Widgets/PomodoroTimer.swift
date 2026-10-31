import AppKit
import Combine
import SwiftUI

/// A Pomodoro timer: focus sessions with short breaks, and a long break every few rounds.
@MainActor
final class PomodoroTimer: ObservableObject {
    static let shared = PomodoroTimer()

    enum Phase: String {
        case focus, shortBreak, longBreak

        var title: String {
            switch self {
            case .focus: "Focus"
            case .shortBreak: "Short break"
            case .longBreak: "Long break"
            }
        }

        var symbol: String { self == .focus ? "brain.head.profile" : "cup.and.saucer.fill" }
        var color: Color { self == .focus ? Color(red: 1, green: 0.42, blue: 0.36) : Color(red: 0.3, green: 0.85, blue: 0.6) }
    }

    @Published private(set) var phase: Phase = .focus
    @Published private(set) var isRunning = false
    @Published private(set) var remaining: TimeInterval
    /// Focus sessions finished in the current round.
    @Published private(set) var completedSessions = 0

    /// When the current phase ends, while the timer runs.
    private(set) var endDate: Date?
    private var ticker: Poll?
    /// The current phase has been started at least once, so new durations wait for the next one.
    private var phaseStarted = false
    /// How long the current phase was when it was first started.
    private var phaseLength: TimeInterval = 0
    /// A focus session has started and hasn't finished, been skipped or been reset.
    private var isInSession = false
    private var settingsObserver: AnyCancellable?

    /// What runs the Shortcut chosen for a session's start or end. The tests count them instead.
    var runShortcut: @MainActor (String) -> Void = { ShortcutsService.shared.run($0, quietly: true) }

    private init() {
        let settings = AppSettings.shared
        remaining = TimeInterval(settings.focusMinutes * 60)
        settingsObserver = Publishers.Merge3(settings.$focusMinutes, settings.$shortBreakMinutes, settings.$longBreakMinutes)
            .dropFirst(3)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, !self.phaseStarted else { return }
                self.remaining = self.duration
            }
    }

    var duration: TimeInterval { Self.duration(of: phase) }
    var progress: Double { duration > 0 ? 1 - remaining / duration : 0 }

    func toggle() {
        isRunning ? pause() : start()
    }

    func start() {
        guard !isRunning else { return }
        if remaining <= 0 { remaining = duration }
        endDate = Date.now.addingTimeInterval(remaining)
        if !phaseStarted {
            phaseLength = duration
            if phase == .focus { beginSession() }
        }
        phaseStarted = true
        isRunning = true
        // Counts down twice a second for the notch; while nobody's looking, only wakes at the end.
        ticker = EnergyCoordinator.shared.schedule(.countdown, deadline: { [weak self] in self?.endDate }) { [weak self] in
            self?.tick()
        }
    }

    func pause() {
        guard isRunning else { return }
        tick()
        isRunning = false
        endDate = nil
        ticker?.cancel()
        ticker = nil
    }

    func reset() {
        pause()
        endSession()
        phase = .focus
        completedSessions = 0
        phaseStarted = false
        remaining = duration
    }

    func skip() {
        let wasRunning = isRunning
        pause()
        advance()
        if wasRunning { start() }
    }

    private func tick() {
        guard let endDate else { return }
        remaining = max(0, endDate.timeIntervalSinceNow)
        if remaining <= 0 { finish() }
    }

    private func finish() {
        let finished = phase
        let ended = endDate ?? .now
        // Cleared first: pause() ticks, and a tick that still sees the end date comes straight back here.
        endDate = nil
        pause()
        if finished == .focus { FocusHistory.shared.add(minutes: Int((phaseLength / 60).rounded()), ended: ended) }
        if AppSettings.shared.timerSound { NSSound(named: "Glass")?.play() }
        advance()
        let message = finished == .focus ? "Focus done. Time for a \(phase == .longBreak ? "long " : "")break." : "Break's over. Back to it."
        LiveActivityCenter.shared.post(LiveNotice(key: "timer", symbol: finished == .focus ? "checkmark.circle.fill" : "bell.fill",
                                                  tint: phase.color, text: "", detail: message, recall: .whole), for: 6)
        if AppSettings.shared.autoStartNextPhase { start() }
    }

    private func advance() {
        if phase == .focus {
            endSession()
            completedSessions += 1
            phase = completedSessions >= AppSettings.shared.sessionsPerRound ? .longBreak : .shortBreak
        } else {
            if phase == .longBreak { completedSessions = 0 }
            phase = .focus
        }
        phaseStarted = false
        remaining = duration
    }

    private func beginSession() {
        isInSession = true
        let shortcut = AppSettings.shared.focusStartShortcut
        if !shortcut.isEmpty { runShortcut(shortcut) }
    }

    /// However a session ends, so a Focus its start turned on doesn't stay on.
    private func endSession() {
        guard isInSession else { return }
        isInSession = false
        let shortcut = AppSettings.shared.focusEndShortcut
        if !shortcut.isEmpty { runShortcut(shortcut) }
    }

    private static func duration(of phase: Phase) -> TimeInterval {
        let settings = AppSettings.shared
        switch phase {
        case .focus: return TimeInterval(settings.focusMinutes * 60)
        case .shortBreak: return TimeInterval(settings.shortBreakMinutes * 60)
        case .longBreak: return TimeInterval(settings.longBreakMinutes * 60)
        }
    }

    // MARK: Snapshots

    func loadSample(remaining: TimeInterval, running: Bool) {
        phase = .focus
        completedSessions = 2
        self.remaining = remaining
        isRunning = running
    }
}
