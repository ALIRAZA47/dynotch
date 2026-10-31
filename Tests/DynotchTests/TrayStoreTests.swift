import Foundation
import Testing
@testable import Dynotch

/// Each test has a store of its own in a folder of its own, so none of them can reach the real Tray.
@MainActor
@Suite(.serialized)
final class TrayStoreTests {
    private let support: URL
    private let file: URL
    private let store: TrayStore
    private static let eightDays: TimeInterval = 8 * 24 * 3600

    init() throws {
        SnapshotRenderer.useScratchDefaults()
        let settings = AppSettings.shared
        settings.trayKeeps = .week
        settings.trayCopiesFiles = false
        support = FileManager.default.temporaryDirectory
            .appendingPathComponent("DynotchTrayTests-\(UUID().uuidString)", isDirectory: true)
        file = support.appendingPathComponent("Screenshot.png")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data("picture".utf8).write(to: file)
        store = TrayStore(support: support)
    }

    deinit {
        try? FileManager.default.removeItem(at: support)
    }

    private var later: Date { .now.addingTimeInterval(Self.eightDays) }

    @Test func aScreenshotLeavesAfterAWeekAndItsFileStays() {
        store.add([file], automatically: true)
        store.tidy(now: later)
        #expect(store.items.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aScreenshotStaysWithinItsWeek() {
        store.add([file], automatically: true)
        store.tidy(now: .now.addingTimeInterval(6 * 24 * 3600))
        #expect(store.items.count == 1)
    }

    @Test func aPinnedScreenshotStays() throws {
        store.add([file], automatically: true)
        store.togglePin(try #require(store.items.first))
        store.tidy(now: later)
        #expect(store.items.count == 1)
    }

    @Test func aFileYouAddedStays() {
        store.add([file])
        store.tidy(now: later)
        #expect(store.items.count == 1)
    }

    @Test func addingAScreenshotByHandKeepsIt() {
        store.add([file], automatically: true)
        store.add([file])
        store.tidy(now: later)
        #expect(store.items.count == 1)
    }

    @Test func aDayIsShorter() {
        AppSettings.shared.trayKeeps = .day
        store.add([file], automatically: true)
        store.tidy(now: .now.addingTimeInterval(25 * 3600))
        #expect(store.items.isEmpty)
    }

    @Test func untilRemovedMeansThat() {
        AppSettings.shared.trayKeeps = .forever
        store.add([file], automatically: true)
        store.tidy(now: later)
        #expect(store.items.count == 1)
    }

    @Test func clearLeavesWhatsPinned() throws {
        let other = support.appendingPathComponent("Notes.txt")
        try Data("text".utf8).write(to: other)
        store.add([file, other])
        store.togglePin(try #require(store.items.first))
        store.clear()
        #expect(store.items.map(\.url) == [file])
    }

    @Test func aPinSurvivesARelaunch() throws {
        store.add([file], automatically: true)
        store.togglePin(try #require(store.items.first))
        let reopened = TrayStore(support: support)
        reopened.load()
        #expect(reopened.items.first?.isPinned == true)
        #expect(reopened.items.first?.isAutomatic == true)
    }

    @Test func aListSavedBeforePinningStillLoads() throws {
        let old = """
        [{"id":"\(UUID().uuidString)","url":"\(file.absoluteString)","isOwned":false,"addedAt":0}]
        """
        try Data(old.utf8).write(to: support.appendingPathComponent("tray.json"))
        let reopened = TrayStore(support: support)
        reopened.load()
        #expect(reopened.items.count == 1)
        #expect(reopened.items.first?.isPinned == false)
        #expect(reopened.items.first?.isAutomatic == false)
    }
}
