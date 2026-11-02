import Foundation
import Testing
@testable import Dynotch

/// A folder of its own for each test, so nothing reaches the real history.
@MainActor
final class FocusHistoryTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dynotch-focus-\(UUID().uuidString)", isDirectory: true)
    private var file: URL { folder.appendingPathComponent("focus-history.jsonl") }
    private let end = Date(timeIntervalSince1970: 1_793_469_600)

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    private func lines() throws -> [String] {
        try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    private func write(_ text: String) throws {
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    @Test func aSessionIsOneLineOfJSONAndNothingElse() throws {
        FocusHistory(folder: folder).add(minutes: 25, ended: end)
        #expect(try lines() == [#"{"end":"2026-10-31T18:00:00Z","minutes":25}"#])
    }

    @Test func linesOnlyEverGrowAtTheEnd() throws {
        let history = FocusHistory(folder: folder)
        history.add(minutes: 25, ended: end)
        let first = try lines()[0]
        history.add(minutes: 50, ended: end.addingTimeInterval(3600))
        #expect(try lines().count == 2)
        #expect(try lines()[0] == first)
    }

    @Test func onlyYouCanReadIt() throws {
        FocusHistory(folder: folder).add(minutes: 25, ended: end)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func aMissingFolderIsMade() throws {
        try FileManager.default.removeItem(at: folder)
        FocusHistory(folder: folder).add(minutes: 25, ended: end)
        #expect(try lines().count == 1)
    }

    @Test func itComesBackAfterARelaunch() {
        FocusHistory(folder: folder).add(minutes: 25, ended: end)
        let next = FocusHistory(folder: folder)
        next.load(now: end)
        #expect(next.sessions == [FocusHistory.Session(end: end, minutes: 25)])
    }

    @Test func nothingThereIsNothingLost() {
        let history = FocusHistory(folder: folder)
        history.load(now: end)
        #expect(history.sessions.isEmpty)
        #expect(history.summary(now: end).sessionsThisWeek == 0)
    }

    @Test func aDamagedLineIsSkippedAndTheRestKept() throws {
        try write(#"""
        {"end":"2026-10-31T17:00:00Z","minutes":25}
        not json at all
        {"end":"2026-10-31T18:00:00Z","minutes":50}

        """#)
        let history = FocusHistory(folder: folder)
        history.load(now: end)
        #expect(history.sessions.map(\.minutes) == [25, 50])
    }

    @Test(arguments: [
        #"{"end":"2026-10-31T18:00:00Z","minutes":0}"#, #"{"end":"2026-10-31T18:00:00Z","minutes":-25}"#,
        #"{"end":"2026-10-31T18:00:00Z","minutes":100000}"#, #"{"end":"2036-10-31T18:00:00Z","minutes":25}"#,
        #"{"end":"2020-10-31T18:00:00Z","minutes":25}"#, #"{"minutes":25}"#,
    ])
    func aLineThatCouldntHaveBeenWrittenHereDoesntCount(line: String) throws {
        try write(line + "\n")
        let history = FocusHistory(folder: folder)
        history.load(now: end)
        #expect(history.sessions.isEmpty)
    }

    /// As after a crash in the middle of a write. Whatever's next starts on a line of its own.
    @Test func aCutOffLastLineDoesntTakeTheNextOneWithIt() throws {
        try write(#"{"end":"2026-10-31T17:00:00Z","minutes":25}"# + "\n" + #"{"end":"2026-10-31T1"#)
        let history = FocusHistory(folder: folder)
        history.load(now: end)
        history.add(minutes: 50, ended: end)
        let next = FocusHistory(folder: folder)
        next.load(now: end)
        #expect(next.sessions.map(\.minutes) == [25, 50])
    }

    @Test func aSessionThatCantBeWrittenWaitsForTheNext() throws {
        let blocked = folder.appendingPathComponent("not-a-folder")
        try Data().write(to: blocked)
        let history = FocusHistory(folder: blocked)
        history.add(minutes: 25, ended: end)
        #expect(history.sessions.count == 1)
        try FileManager.default.removeItem(at: blocked)
        history.add(minutes: 50, ended: end)
        let next = FocusHistory(folder: blocked)
        next.load(now: end)
        #expect(next.sessions.map(\.minutes) == [25, 50])
    }

    @Test(arguments: [0, -5, 100_000])
    func aLengthThatMakesNoSenseIsntASession(minutes: Int) {
        let history = FocusHistory(folder: folder)
        history.add(minutes: minutes, ended: end)
        #expect(history.sessions.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: The summary

    /// A week from Sunday, in UTC. `end` is a Saturday, the last day of it.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 1
        return calendar
    }

    @Test func todayAndTheWeek() {
        let history = FocusHistory(folder: folder)
        history.add(minutes: 25, ended: end)
        history.add(minutes: 25, ended: end.addingTimeInterval(-3600))
        history.add(minutes: 50, ended: end.addingTimeInterval(-24 * 3600))
        history.add(minutes: 100, ended: end.addingTimeInterval(-5 * 24 * 3600))
        let summary = history.summary(now: end, calendar: calendar)
        #expect(summary.sessionsToday == 2)
        #expect(summary.minutesToday == 50)
        #expect(summary.sessionsThisWeek == 4)
        #expect(summary.minutesThisWeek == 200)
        #expect(summary.days == [0, 100, 0, 0, 0, 50, 50])
        #expect(summary.today == 6)
    }

    @Test func lastWeekDoesntCount() {
        let history = FocusHistory(folder: folder)
        history.add(minutes: 25, ended: end.addingTimeInterval(-7 * 24 * 3600))
        let summary = history.summary(now: end, calendar: calendar)
        #expect(summary.sessionsThisWeek == 0)
        #expect(summary.days == [0, 0, 0, 0, 0, 0, 0])
    }

    @Test func aWeekCanStartOnMonday() {
        var monday = calendar
        monday.firstWeekday = 2
        let history = FocusHistory(folder: folder)
        history.add(minutes: 25, ended: end)
        let summary = history.summary(now: end, calendar: monday)
        #expect(summary.today == 5)
        #expect(summary.days == [0, 0, 0, 0, 0, 25, 0])
    }

    @Test func aSessionThatEndsAfterMidnightCountsForThatDay() {
        let midnight = calendar.startOfDay(for: end)
        let history = FocusHistory(folder: folder)
        history.add(minutes: 25, ended: midnight.addingTimeInterval(60))
        #expect(history.summary(now: end, calendar: calendar).sessionsToday == 1)
        history.add(minutes: 25, ended: midnight.addingTimeInterval(-60))
        #expect(history.summary(now: end, calendar: calendar).sessionsToday == 1)
    }

    @Test func minutesInFewWords() {
        #expect(FocusStrip.time(50) == "50m")
        #expect(FocusStrip.time(60) == "1h")
        #expect(FocusStrip.time(225) == "3h 45m")
    }

    @Test func aDayWithNoneSaysSoInWords() {
        var summary = FocusHistory.Summary()
        summary.sessionsThisWeek = 2
        summary.minutesThisWeek = 50
        #expect(FocusStrip.spoken(summary) == "Focus today: none yet. This week: 2 sessions, 50 min.")
    }

    /// A write that stopped part way leaves a cut-off line for the next one to start after.
    @Test func aFailedWriteLeavesTheNextOnALineOfItsOwn() throws {
        try write(#"{"end":"2026-10-31T17:00:00Z","minutes":25}"# + "\n")
        let history = FocusHistory(folder: folder)
        history.load(now: end)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
        history.add(minutes: 50, ended: end)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        history.add(minutes: 75, ended: end)
        let next = FocusHistory(folder: folder)
        next.load(now: end)
        #expect(next.sessions.map(\.minutes) == [25, 50, 75])
    }
}

/// Shortcuts that run by themselves, with a stand-in for what runs them.
@MainActor
@Suite(.serialized)
struct ShortcutQueueTests {
    /// Each run waits until it's let go, so what's in turn is what the test says it is.
    private final class Runs {
        var started: [String] = []
        var waiting: [CheckedContinuation<Bool, Never>] = []

        func finish(_ succeeded: Bool = true) {
            if !waiting.isEmpty { waiting.removeFirst().resume(returning: succeeded) }
        }
    }

    private let service = ShortcutsService.shared
    private let runs = Runs()
    private let original = ShortcutsService.shared.runner

    init() {
        SnapshotRenderer.useScratchDefaults()
        service.runner = { [runs] name in
            runs.started.append(name)
            return await withCheckedContinuation { runs.waiting.append($0) }
        }
    }

    private func wait(until condition: () -> Bool) async {
        let limit = Date.now.addingTimeInterval(30)
        while !condition(), .now < limit { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func theyGoOneAtATimeInOrderAndNoneIsDropped() async {
        service.runInTurn("Focus On")
        service.runInTurn("Focus Off")
        service.runInTurn("Focus On")
        await wait { runs.started.count == 1 }
        #expect(runs.started == ["Focus On"])
        runs.finish()
        await wait { runs.started.count == 2 }
        #expect(runs.started == ["Focus On", "Focus Off"])
        runs.finish(false)
        await wait { runs.started.count == 3 }
        #expect(runs.started == ["Focus On", "Focus Off", "Focus On"])
        runs.finish()
        await wait { runs.waiting.isEmpty }
        service.runner = original
    }
}

/// Through the real timer, with a stand-in for the Shortcut runner. The history is the scratch one.
@MainActor
@Suite(.serialized)
struct PomodoroSessionTests {
    private let timer = PomodoroTimer.shared
    private let settings: AppSettings
    private let history = FocusHistory.shared

    init() {
        SnapshotRenderer.useScratchDefaults()
        settings = AppSettings.shared
        settings.timerSound = false
        settings.autoStartNextPhase = false
        settings.focusMinutes = 1
        settings.focusStartShortcut = ""
        settings.focusEndShortcut = ""
        timer.reset()
        history.loadSample(days: [])
    }

    /// Starts a focus phase that ends at once, whatever it says it lasts.
    private func runOutTheSession() {
        timer.loadSample(remaining: 0.02, running: false)
        timer.start()
        let limit = Date.now.addingTimeInterval(30)
        while timer.phase == .focus, .now < limit { RunLoop.main.run(until: .now.addingTimeInterval(0.02)) }
    }

    private func catchShortcuts() -> () -> [String] {
        var ran: [String] = []
        timer.runShortcut = { ran.append($0) }
        return { ran }
    }

    private func useShortcuts() {
        settings.focusStartShortcut = "Focus On"
        settings.focusEndShortcut = "Focus Off"
    }

    @Test func aRunFolderIsNeverTheRealOne() {
        let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #expect(!URL.dynotchSupport.path.hasPrefix(real.path))
    }

    @Test func aFinishedSessionIsRemembered() {
        runOutTheSession()
        #expect(history.sessions.map(\.minutes) == [1])
        #expect(history.summary().sessionsToday == 1)
    }

    @Test func itsSavedInTheScratchFolder() throws {
        runOutTheSession()
        let saved = try String(contentsOf: URL.dynotchSupport.appendingPathComponent("focus-history.jsonl"), encoding: .utf8)
        #expect(saved.contains(#""minutes":1"#))
    }

    @Test func itKeepsTheLengthItStartedWith() {
        timer.loadSample(remaining: 0.02, running: false)
        timer.start()
        settings.focusMinutes = 45
        let limit = Date.now.addingTimeInterval(30)
        while timer.phase == .focus, .now < limit { RunLoop.main.run(until: .now.addingTimeInterval(0.02)) }
        #expect(history.sessions.map(\.minutes) == [1])
    }

    @Test func aSkippedSessionIsntASession() {
        timer.start()
        timer.skip()
        #expect(timer.phase == .shortBreak)
        #expect(history.sessions.isEmpty)
    }

    @Test func aResetSessionIsntASession() {
        timer.start()
        timer.reset()
        #expect(history.sessions.isEmpty)
    }

    @Test func aBreakIsntASession() {
        settings.shortBreakMinutes = 0
        defer { settings.shortBreakMinutes = 5 }
        timer.skip()
        #expect(timer.phase == .shortBreak)
        timer.start()
        let limit = Date.now.addingTimeInterval(30)
        while timer.phase == .shortBreak, .now < limit { RunLoop.main.run(until: .now.addingTimeInterval(0.02)) }
        #expect(timer.phase == .focus)
        #expect(history.sessions.isEmpty)
    }

    @Test func noShortcutChosenRunsNothing() {
        let ran = catchShortcuts()
        runOutTheSession()
        #expect(ran().isEmpty)
    }

    @Test func aSessionRunsItsShortcutsAtEachEnd() {
        let ran = catchShortcuts()
        useShortcuts()
        timer.start()
        #expect(ran() == ["Focus On"])
        timer.reset()
        #expect(ran() == ["Focus On", "Focus Off"])
    }

    @Test func aSessionThatRunsOutRunsItsEnd() {
        let ran = catchShortcuts()
        useShortcuts()
        runOutTheSession()
        #expect(ran() == ["Focus On", "Focus Off"])
    }

    @Test func pausingAndResumingRunsNothingMore() {
        let ran = catchShortcuts()
        useShortcuts()
        timer.start()
        timer.pause()
        timer.start()
        #expect(ran() == ["Focus On"])
        timer.reset()
    }

    @Test func skippingEndsTheSession() {
        let ran = catchShortcuts()
        useShortcuts()
        timer.start()
        timer.skip()
        #expect(ran() == ["Focus On", "Focus Off"])
        timer.reset()
    }

    @Test func aBreakRunsNoShortcuts() {
        let ran = catchShortcuts()
        useShortcuts()
        timer.skip()
        #expect(ran().isEmpty)
        timer.start()
        timer.pause()
        #expect(ran().isEmpty)
        timer.reset()
        #expect(ran().isEmpty)
    }

    @Test func resettingWithNoSessionRunsNothing() {
        let ran = catchShortcuts()
        useShortcuts()
        timer.reset()
        #expect(ran().isEmpty)
    }

    @Test func aPausedSessionStillEnds() {
        let ran = catchShortcuts()
        useShortcuts()
        timer.start()
        timer.pause()
        timer.reset()
        #expect(ran() == ["Focus On", "Focus Off"])
    }
}
