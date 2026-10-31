import Foundation
import Testing
@testable import Dynotch

struct LevelCommandTests {
    @Test func readsLevels() {
        #expect(LevelCommand.parse("vol 30") == .volume(30))
        #expect(LevelCommand.parse("Volume 30%") == .volume(30))
        #expect(LevelCommand.parse("bright 60") == .brightness(60))
        #expect(LevelCommand.parse("brightness 100") == .brightness(100))
        #expect(LevelCommand.parse("vol 0") == .volume(0))
    }

    @Test(arguments: ["vol", "vol 101", "vol -1", "vol loud", "volcano 30", "vol 30 now"])
    func leavesTheRestAlone(text: String) {
        #expect(LevelCommand.parse(text) == nil)
    }
}

@MainActor
struct KeepAwakeTextTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func readsALength() {
        #expect(KeepAwakeText.end(from: "2h", now: now) == now.addingTimeInterval(7200))
        #expect(KeepAwakeText.end(from: "30 min", now: now) == now.addingTimeInterval(1800))
        #expect(KeepAwakeText.end(from: "1h30", now: now) == now.addingTimeInterval(5400))
    }

    @Test func readsATime() throws {
        let end = try #require(KeepAwakeText.end(from: "until 5pm"))
        #expect(end > .now)
        #expect(Calendar.current.component(.hour, from: end) == 17)
    }

    @Test func nothingItCanReadGivesNoEnd() {
        #expect(KeepAwakeText.end(from: "until later", now: now) == nil)
        #expect(KeepAwakeText.end(from: "soon", now: now) == nil)
    }
}

@MainActor
@Suite(.serialized)
struct CommandEngineTests {
    private let viewModel: NotchViewModel

    init() {
        SnapshotRenderer.useScratchDefaults()
        viewModel = NotchViewModel(geometry: NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                                           closedSize: CGSize(width: 186, height: 37), hasHardwareNotch: true))
    }

    private func ids(_ text: String) -> [String] {
        CommandEngine.results(for: text, in: viewModel).map(\.id)
    }

    @Test func aLevelIsNotATimer() {
        #expect(ids("vol 30") == ["volume"])
    }

    @Test func aKeepAwakeLengthIsNotATimer() {
        let results = CommandEngine.results(for: "awake 2h", in: viewModel)
        #expect(results.first?.id == "awake")
        #expect(results.first?.title.hasPrefix("Keep the Mac awake until") == true)
        #expect(results.contains { $0.id == "timer" } == false)
    }

    @Test func aKeepAwakeWithNoLengthStillToggles() {
        #expect(ids("awake").contains("awake"))
    }

    @Test func aSettingsPageCanBeOpenedByName() {
        #expect(ids("settings tray") == ["settings-tray"])
        #expect(ids("settings live").contains("settings-activities"))
    }

    @Test func plainSettingsStillOpensSettings() {
        #expect(ids("settings").contains("settings"))
    }
}
