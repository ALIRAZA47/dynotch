import Foundation
import Testing
@testable import Dynotch

/// A focus phase here lasts no time at all, so it's at zero the next time the timer looks.
@MainActor
@Suite(.serialized)
struct PomodoroTimerTests {
    private let timer = PomodoroTimer.shared

    init() {
        SnapshotRenderer.useScratchDefaults()
        let settings = AppSettings.shared
        settings.timerSound = false
        settings.autoStartNextPhase = false
        settings.focusMinutes = 0
        timer.reset()
    }

    /// Lets the countdown's timer fire, however long the phase takes to change.
    private func runUntilThePhaseEnds() {
        let limit = Date.now.addingTimeInterval(5)
        while timer.phase == .focus, .now < limit {
            RunLoop.main.run(until: .now.addingTimeInterval(0.05))
        }
    }

    @Test func aCountdownReachingZeroMovesToTheBreak() {
        timer.start()
        runUntilThePhaseEnds()
        #expect(!timer.isRunning)
        #expect(timer.endDate == nil)
        #expect(timer.phase == .shortBreak)
        #expect(timer.completedSessions == 1)
    }

    @Test func pausingAtZeroStillFinishesThePhase() {
        timer.start()
        timer.pause()
        #expect(!timer.isRunning)
        #expect(timer.phase == .shortBreak)
        #expect(timer.remaining == TimeInterval(AppSettings.shared.shortBreakMinutes * 60))
    }

    @Test func autoStartCarriesOnIntoTheBreak() {
        AppSettings.shared.autoStartNextPhase = true
        timer.start()
        runUntilThePhaseEnds()
        #expect(timer.isRunning)
        #expect(timer.phase == .shortBreak)
        #expect(timer.endDate != nil)
        timer.reset()
    }
}
