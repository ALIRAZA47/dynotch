import Foundation
import Testing
@testable import Dynotch

/// Rows here are made up, since a real one would flip Dark Mode or sleep the display.
@MainActor
@Suite(.serialized)
struct CommandHistoryTests {
    private let viewModel: NotchViewModel
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let day: TimeInterval = 24 * 3600

    init() {
        SnapshotRenderer.useScratchDefaults()
        AppSettings.shared.learnsCommands = true
        CommandHistory.forget()
        viewModel = NotchViewModel(geometry: NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                                           closedSize: CGSize(width: 186, height: 37), hasHardwareNotch: true))
    }

    private var ids: [String] { CommandEngine.results(for: "", in: viewModel).map(\.id) }

    private func row(_ id: String, _ outcome: CommandOutcome) -> CommandResult {
        CommandResult(id: id, symbol: "circle", tint: .gray, title: id) { _ in outcome }
    }

    // MARK: Ranking

    @Test func moreUseRanksHigher() {
        for _ in 0..<3 { CommandHistory.record("stopwatch", now: now) }
        CommandHistory.record("pomodoro", now: now)
        #expect(CommandHistory.ranked(now: now) == ["stopwatch", "pomodoro"])
    }

    @Test func aRecentUseRanksAboveAnOldOne() {
        CommandHistory.record("stopwatch", now: now)
        CommandHistory.record("pomodoro", now: now.addingTimeInterval(day))
        #expect(CommandHistory.ranked(now: now.addingTimeInterval(day)) == ["pomodoro", "stopwatch"])
    }

    @Test func heavyUseOutlastsOneRecentUse() {
        for _ in 0..<10 { CommandHistory.record("stopwatch", now: now) }
        let later = now.addingTimeInterval(14 * day)
        CommandHistory.record("pomodoro", now: later)
        #expect(CommandHistory.ranked(now: later) == ["stopwatch", "pomodoro"])
    }

    @Test func lightUseFadesBehindOneRecentUse() {
        for _ in 0..<3 { CommandHistory.record("stopwatch", now: now) }
        let later = now.addingTimeInterval(14 * day)
        CommandHistory.record("pomodoro", now: later)
        #expect(CommandHistory.ranked(now: later) == ["pomodoro", "stopwatch"])
    }

    @Test func usesAddUpAsTheyFade() {
        CommandHistory.record("stopwatch", now: now)
        CommandHistory.record("pomodoro", now: now)
        CommandHistory.record("pomodoro", now: now.addingTimeInterval(CommandHistory.halfLife))
        let uses = CommandHistory.Use(count: 1.5, last: now.addingTimeInterval(CommandHistory.halfLife))
        #expect(uses.weight(at: now.addingTimeInterval(CommandHistory.halfLife)) == 1.5)
        #expect(CommandHistory.ranked(now: now.addingTimeInterval(CommandHistory.halfLife)) == ["pomodoro", "stopwatch"])
    }

    @Test func aClockSetBackDoesntAddWeight() {
        let use = CommandHistory.Use(count: 2, last: now)
        #expect(use.weight(at: now.addingTimeInterval(-day)) == 2)
    }

    @Test func onlySoManyAreKept() {
        for index in 0..<(CommandHistory.limit + 5) {
            CommandHistory.record("tab-\(index)", now: now.addingTimeInterval(Double(index)))
        }
        let ranked = CommandHistory.ranked(now: now.addingTimeInterval(1000))
        #expect(ranked.count == CommandHistory.limit)
        #expect(!ranked.contains("tab-0"))
        #expect(ranked.contains("tab-\(CommandHistory.limit + 4)"))
    }

    // MARK: The empty field

    @Test func withNothingUsedItShowsTheSameSixAsEver() {
        #expect(ids == ["timer", "note", "remind", "dark", "profile", "sum"])
        #expect(!CommandEngine.results(for: "", in: viewModel).map(\.isLearned).contains(true))
    }

    @Test func whatsUsedComesFirstAndTheRestFill() {
        CommandHistory.record("stopwatch")
        CommandHistory.record("stopwatch")
        CommandHistory.record("pomodoro")
        #expect(ids == ["stopwatch", "pomodoro", "timer", "note", "remind", "dark"])
        #expect(CommandEngine.results(for: "", in: viewModel).map(\.isLearned) == [true, true, false, false, false, false])
    }

    @Test func aStarterThatsBeenUsedDoesntShowTwice() {
        CommandHistory.record("note")
        #expect(ids == ["note", "timer", "remind", "dark", "profile", "sum"])
    }

    @Test func itNeverShowsMoreThanFit() {
        for id in ["stopwatch", "pomodoro", "mic", "awake", "color", "screenshot", "sleep", "tab-tray"] { CommandHistory.record(id) }
        #expect(ids.count == CommandEngine.maximumResults)
        #expect(!CommandEngine.results(for: "", in: viewModel).map(\.isLearned).contains(false))
    }

    @Test func aPlaceOrAPageComesBack() {
        CommandHistory.record("tab-tray")
        CommandHistory.record("settings-tray")
        CommandHistory.record("settings")
        let results = CommandEngine.results(for: "", in: viewModel)
        #expect(Set(results.prefix(3).map(\.id)) == ["tab-tray", "settings-tray", "settings"])
        #expect(results.prefix(3).allSatisfy { $0.action != nil })
    }

    /// The first row is one Return away with nothing typed. These get typed out, and a second Return
    /// runs them.
    @Test func whatCantBeTakenBackIsTypedOutFirst() {
        CommandHistory.record("sleep")
        let row = CommandEngine.results(for: "", in: viewModel)[0]
        #expect(row.id == "sleep")
        #expect(row.hint == "sleep")
        viewModel.run(row)
        #expect(viewModel.commandQuery == "sleep")
        #expect(CommandHistory.ranked() == ["sleep"])
    }

    @Test func aProfileIsTypedOutToo() throws {
        let profile = Profile(id: UUID(), name: "Work", rule: nil, values: [:])
        ProfileStore.shared.loadSample([profile], active: nil)
        defer { ProfileStore.shared.loadSample([], active: nil) }
        CommandHistory.record("profile-\(profile.id)")
        let row = try #require(CommandEngine.results(for: "", in: viewModel).first)
        viewModel.run(row)
        #expect(viewModel.commandQuery == "profile Work")
    }

    @Test func whatsGoneDoesntComeBack() {
        CommandHistory.record("shortcut-Deleted long ago")
        CommandHistory.record("profile-00000000-0000-0000-0000-000000000000")
        CommandHistory.record("settings-nowhere")
        CommandHistory.record("something-from-an-old-version")
        #expect(ids == ["timer", "note", "remind", "dark", "profile", "sum"])
    }

    @Test func aMusicCommandWaitsForAPlayer() {
        CommandHistory.record("next")
        NowPlayingService.shared.loadSample(nil)
        #expect(!ids.contains("next"))
    }

    // MARK: What's counted

    @Test func runningARowCountsIt() {
        viewModel.run(row("stopwatch", .close))
        viewModel.run(row("tab-tray", .stay))
        #expect(Set(CommandHistory.ranked()) == ["stopwatch", "tab-tray"])
    }

    @Test func onlyAskingForMoreIsntAUse() {
        viewModel.run(row("note", .fill("note ")))
        #expect(CommandHistory.ranked().isEmpty)
        #expect(viewModel.commandQuery == "note ")
    }

    @Test func aRowThatOnlySaysSomethingIsntAUse() {
        viewModel.run(CommandResult(id: "stopwatch", symbol: "circle", tint: .gray, title: "Nothing to do"))
        #expect(CommandHistory.ranked().isEmpty)
    }

    @Test(arguments: [
        "clip-7A0B2C3E", "note-7A0B2C3E", "file-7A0B2C3E", "clip-none", "clip-off", "nothing",
        "output-73", "connect-aa-bb", "disconnect-aa-bb", "clear-tray", "stop-recording", "made-up",
    ])
    func whatCantComeBackIsntCounted(id: String) {
        CommandEngine.noteUse(of: id)
        #expect(CommandHistory.ranked().isEmpty)
    }

    /// The real rows for what was typed: their IDs say nothing of it.
    @Test func whatsTypedNeverReachesTheHistory() throws {
        let typed = ["note Dear diary, my secret", "remind Call Sam 5pm", "tea 4m", "18% of 240"]
        for text in typed {
            for result in CommandEngine.results(for: text, in: viewModel) { CommandEngine.noteUse(of: result.id) }
        }
        let stored = String(decoding: try #require(UserDefaults.dynotch.data(forKey: "commandHistory")), as: UTF8.self)
        for word in ["Dear", "diary", "secret", "Sam", "tea", "240"] { #expect(!stored.contains(word)) }
    }

    @Test func allAnswersCountAsTheOneRow() {
        #expect(CommandEngine.learnedID(of: "sum") == "sum")
        #expect(CommandEngine.learnedID(of: "convert") == "sum")
    }

    // MARK: Turning it off

    @Test func turningItOffForgets() {
        CommandHistory.record("stopwatch")
        AppSettings.shared.learnsCommands = false
        #expect(CommandHistory.ranked().isEmpty)
        CommandEngine.noteUse(of: "stopwatch")
        #expect(CommandHistory.ranked().isEmpty)
        #expect(ids == ["timer", "note", "remind", "dark", "profile", "sum"])
        AppSettings.shared.learnsCommands = true
    }

    /// Anything can write to the defaults, and what comes back is only ever matched against real rows.
    @Test func aDamagedHistoryIsIgnored() {
        UserDefaults.dynotch.set(Data("not json".utf8), forKey: "commandHistory")
        #expect(CommandHistory.ranked().isEmpty)
        #expect(ids.count == 6)
    }
}

/// Names typed in full, which a timer shouldn't get to first. The lists are samples: nothing here
/// reaches the real Shortcuts.
@MainActor
@Suite(.serialized)
struct CommandRowNameTests {
    private let viewModel: NotchViewModel

    init() {
        SnapshotRenderer.useScratchDefaults()
        viewModel = NotchViewModel(geometry: NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                                           closedSize: CGSize(width: 186, height: 37), hasHardwareNotch: true))
    }

    private func first(_ text: String) -> String? { CommandEngine.results(for: text, in: viewModel).first?.id }

    @Test(arguments: ["Water 8", "Log 2 glasses", "Timer 25"])
    func aShortcutEndingInANumberIsntATimer(name: String) {
        ShortcutsService.shared.loadSample([name])
        defer { ShortcutsService.shared.loadSample([]) }
        #expect(first("run \(name)") == "shortcut-\(name)")
        #expect(!CommandEngine.results(for: "run \(name)", in: viewModel).map(\.id).contains("timer"))
    }

    @Test func aProfileEndingInANumberIsntATimer() {
        let profile = Profile(id: UUID(), name: "Work 2", rule: nil, values: [:])
        ProfileStore.shared.loadSample([profile], active: nil)
        defer { ProfileStore.shared.loadSample([], active: nil) }
        #expect(first("profile Work 2") == "profile-\(profile.id)")
        #expect(!CommandEngine.results(for: "profile Work 2", in: viewModel).map(\.id).contains("timer"))
    }

    @Test func aTimerCalledRunIsStillATimer() {
        ShortcutsService.shared.loadSample(["Morning routine"])
        defer { ShortcutsService.shared.loadSample([]) }
        #expect(first("run 30m") == "timer")
        #expect(first("run Morning") == "shortcut-Morning routine")
    }

    @Test func theExactNameComesFirst() {
        ShortcutsService.shared.loadSample(["Archive Backup", "Backup", "Backup Photos"])
        defer { ShortcutsService.shared.loadSample([]) }
        #expect(first("run Backup") == "shortcut-Backup")
        #expect(first("run backup") == "shortcut-Backup")
        let (late, work) = (Profile(id: UUID(), name: "Work Late", rule: nil, values: [:]), Profile(id: UUID(), name: "Work", rule: nil, values: [:]))
        ProfileStore.shared.loadSample([late, work], active: nil)
        defer { ProfileStore.shared.loadSample([], active: nil) }
        #expect(first("profile Work") == "profile-\(work.id)")
    }
}
