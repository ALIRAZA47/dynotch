import Foundation
import SwiftUI
import Testing
@testable import Dynotch

struct NoticeQueueTests {
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private func notice(_ key: String, timing: LiveNotice.Timing = .waits) -> LiveNotice {
        LiveNotice(key: key, symbol: "bell", tint: .white, text: key, timing: timing)
    }

    private func entry(_ key: String, for duration: TimeInterval = 5, timing: LiveNotice.Timing = .waits) -> NoticeQueue.Entry {
        NoticeQueue.Entry(notice: notice(key, timing: timing), duration: duration)
    }

    private var meter: LiveNotice {
        LiveNotice(key: "volume", symbol: "speaker.wave.2.fill", tint: .white, kind: .meter(0.5))
    }

    @Test func aNoticeEndsWhenItsTimeIsUp() {
        var queue = NoticeQueue()
        queue.post(entry("a", for: 5), isQuiet: false, now: at(0))
        #expect(queue.nextChange == at(5))
        queue.tick(now: at(5))
        #expect(queue.visible == nil)
        #expect(queue.nextChange == nil)
    }

    @Test func aSecondNoticeWaitsItsTurn() {
        var queue = NoticeQueue()
        queue.post(entry("a", for: 5), isQuiet: false, now: at(0))
        queue.post(entry("b", for: 5), isQuiet: false, now: at(0.5))
        #expect(queue.visible?.key == "a")
        // The first makes way after its shortest turn, not when its five seconds are up.
        #expect(queue.nextChange == at(NoticeQueue.shortestTurn))
        queue.tick(now: at(NoticeQueue.shortestTurn))
        #expect(queue.visible?.key == "b")
        #expect(queue.waiting.isEmpty)
    }

    @Test func aNoticeThatHasHadItsMomentMakesWayAtOnce() {
        var queue = NoticeQueue()
        queue.post(entry("a", for: 5), isQuiet: false, now: at(0))
        queue.post(entry("b", for: 5), isQuiet: false, now: at(3))
        #expect(queue.nextChange == at(3))
    }

    @Test func noticesInAQueueGetShorterTurns() {
        var queue = NoticeQueue()
        queue.post(entry("a", for: 2), isQuiet: false, now: at(0))
        queue.post(entry("b", for: 8), isQuiet: false, now: at(0))
        queue.post(entry("c", for: 8), isQuiet: false, now: at(0))
        queue.tick(now: at(2))
        #expect(queue.visible?.key == "b")
        #expect(queue.nextChange == at(2 + NoticeQueue.busyTurn))
    }

    @Test func theSameKeyUpdatesInPlace() {
        var queue = NoticeQueue()
        queue.post(entry("a", for: 5), isQuiet: false, now: at(0))
        var update = entry("a", for: 5)
        update.notice.text = "again"
        queue.post(update, isQuiet: false, now: at(1))
        #expect(queue.visible?.text == "again")
        #expect(queue.waiting.isEmpty)
        #expect(queue.nextChange == at(6))
    }

    @Test func theSameKeyUpdatesItsPlaceInLine() {
        var queue = NoticeQueue()
        queue.post(entry("a"), isQuiet: false, now: at(0))
        queue.post(entry("b"), isQuiet: false, now: at(0))
        var update = entry("b")
        update.notice.text = "again"
        queue.post(update, isQuiet: false, now: at(0))
        #expect(queue.waiting.map(\.notice.text) == ["again"])
    }

    @Test func whatCantWaitGoesNext() {
        var queue = NoticeQueue()
        queue.post(entry("a"), isQuiet: false, now: at(0))
        queue.post(entry("b"), isQuiet: false, now: at(0))
        queue.post(entry("c", timing: .always), isQuiet: false, now: at(0))
        #expect(queue.waiting.map(\.notice.key) == ["c", "b"])
    }

    @Test func aFullLineKeepsWhatCantWait() {
        var queue = NoticeQueue()
        queue.post(entry("first"), isQuiet: false, now: at(0))
        for index in 0..<NoticeQueue.mostWaiting { queue.post(entry("n\(index)"), isQuiet: false, now: at(0)) }
        queue.post(entry("code", timing: .always), isQuiet: false, now: at(0))
        #expect(queue.waiting.first?.notice.key == "code")
        queue.post(entry("later"), isQuiet: false, now: at(0))
        #expect(queue.waiting.first?.notice.key == "code")
        #expect(queue.waiting.count == NoticeQueue.mostWaiting)
    }

    @Test func aRunOfUpdatesCantKeepOthersWaiting() {
        var queue = NoticeQueue()
        queue.post(entry("script", for: 5), isQuiet: false, now: at(0))
        queue.post(entry("other"), isQuiet: false, now: at(0.5))
        for tick in 1...3 { queue.post(entry("script", for: 5), isQuiet: false, now: at(Double(tick) * 0.4)) }
        queue.tick(now: at(NoticeQueue.shortestTurn))
        #expect(queue.visible?.key == "other")
    }

    @Test func theLineHasAnEnd() {
        var queue = NoticeQueue()
        queue.post(entry("first"), isQuiet: false, now: at(0))
        for index in 0..<20 { queue.post(entry("n\(index)"), isQuiet: false, now: at(0)) }
        #expect(queue.waiting.count == NoticeQueue.mostWaiting)
        #expect(queue.waiting.last?.notice.key == "n19")
    }

    @Test func aMeterSitsOnTopAndTheNoticeGetsItsTimeBack() {
        var queue = NoticeQueue()
        queue.post(entry("message", for: 5), isQuiet: false, now: at(0))
        queue.showMeter(meter, for: 1.6, now: at(1))
        #expect(queue.visible?.key == "volume")
        queue.tick(now: at(2.6))
        #expect(queue.visible?.key == "message")
        // Four of its five seconds were left when the meter came.
        #expect(queue.nextChange == at(6.6))
    }

    @Test func aNoticeWaitingShortensTheOneUnderAMeter() {
        var queue = NoticeQueue()
        queue.post(entry("message", for: 5), isQuiet: false, now: at(0))
        queue.showMeter(meter, for: 1.6, now: at(1))
        queue.post(entry("next", for: 5), isQuiet: false, now: at(1.5))
        queue.tick(now: at(2.6))
        #expect(queue.visible?.key == "message")
        #expect(queue.nextChange == at(2.6 + NoticeQueue.shortestTurn))
    }

    @Test func aMeterWithNothingUnderItJustEnds() {
        var queue = NoticeQueue()
        queue.showMeter(meter, for: 1.6, now: at(0))
        queue.tick(now: at(1.6))
        #expect(queue.visible == nil)
        #expect(queue.nextChange == nil)
    }

    @Test func thePointerHoldsANoticeUntilItLeaves() {
        var queue = NoticeQueue()
        queue.post(entry("a", for: 2.6), isQuiet: false, now: at(0))
        queue.setHeldByPointer(true, now: at(1))
        queue.tick(now: at(30))
        #expect(queue.visible?.key == "a")
        queue.setHeldByPointer(false, now: at(30))
        #expect(queue.nextChange == at(30 + NoticeQueue.afterHold))
        queue.tick(now: at(30 + NoticeQueue.afterHold))
        #expect(queue.visible == nil)
    }

    @Test func aNoticeArrivingUnderThePointerStaysToo() {
        var queue = NoticeQueue()
        queue.setHeldByPointer(true, now: at(0))
        queue.post(entry("a", for: 2), isQuiet: false, now: at(1))
        queue.tick(now: at(10))
        #expect(queue.visible?.key == "a")
    }

    @Test func aHoldCantLastForever() {
        var queue = NoticeQueue()
        queue.post(entry("a", for: 2), isQuiet: false, now: at(0))
        queue.setHeldByPointer(true, now: at(0))
        queue.tick(now: at(NoticeQueue.longestHold))
        queue.tick(now: at(NoticeQueue.longestHold + 2))
        #expect(queue.visible == nil)
    }

    @Test func dismissingShowsTheNext() {
        var queue = NoticeQueue()
        queue.post(entry("a"), isQuiet: false, now: at(0))
        queue.post(entry("b"), isQuiet: false, now: at(0))
        queue.dismiss(now: at(1))
        #expect(queue.visible?.key == "b")
    }

    @Test func whileQuietNoticesWaitOrGoAccordingToTheirTiming() {
        var queue = NoticeQueue()
        queue.post(entry("message", timing: .waits), isQuiet: true, now: at(0))
        queue.post(entry("rain", timing: .perishes), isQuiet: true, now: at(0))
        #expect(queue.visible == nil)
        #expect(queue.held.map(\.notice.key) == ["message"])
        queue.post(entry("muted", timing: .always), isQuiet: true, now: at(0))
        #expect(queue.visible?.key == "muted")
    }

    @Test func goingQuietClearsTheNotchOfWhatCanWait() {
        var queue = NoticeQueue()
        queue.post(entry("message", timing: .waits), isQuiet: false, now: at(0))
        queue.post(entry("rain", timing: .perishes), isQuiet: false, now: at(0))
        queue.post(entry("timer", timing: .always), isQuiet: false, now: at(0))
        queue.goQuiet(now: at(1))
        #expect(queue.visible?.key == "timer")
        #expect(queue.held.map(\.notice.key) == ["message"])
    }

    @Test func aFewHeldNoticesComeOutInTurn() {
        var queue = NoticeQueue()
        queue.post(entry("a"), isQuiet: true, now: at(0))
        queue.post(entry("b"), isQuiet: true, now: at(0))
        queue.endQuiet(now: at(10))
        #expect(queue.visible?.key == "a")
        #expect(queue.waiting.map(\.notice.key) == ["b"])
        #expect(queue.held.isEmpty)
    }

    @Test func whatShouldStayHiddenDoesNotComeOut() {
        var queue = NoticeQueue()
        queue.post(entry("peek"), isQuiet: true, now: at(0))
        queue.post(entry("download"), isQuiet: true, now: at(0))
        queue.endQuiet(now: at(10), holdingBack: ["peek"])
        #expect(queue.visible?.key == "download")
        #expect(queue.waiting.isEmpty)
        #expect(queue.held.isEmpty)
    }

    @Test func manyHeldNoticesComeOutAsOne() {
        var queue = NoticeQueue()
        for key in ["a", "b", "c", "d"] { queue.post(entry(key), isQuiet: true, now: at(0)) }
        queue.endQuiet(now: at(10))
        #expect(queue.visible?.key == "held")
        #expect(queue.visible?.text == "4 new")
        #expect(queue.visible?.detail == "Waited for you: a, b, c")
        #expect(queue.visible?.actions.first?.kind == .showRecent)
        #expect(queue.held.isEmpty)
    }
}
