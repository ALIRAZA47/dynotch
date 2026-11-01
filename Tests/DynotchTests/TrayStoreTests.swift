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

    // MARK: What comes from outside

    private func filesInTheFolder() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: store.folder.path)
    }

    /// Screenshots and downloads come from folders macOS keeps other apps out of, and the Tray's isn't one.
    @Test func whatComesByItselfIsNeverCopied() throws {
        AppSettings.shared.trayCopiesFiles = true
        defer { AppSettings.shared.trayCopiesFiles = false }
        store.add([file], automatically: true)
        #expect(store.items.map(\.url) == [file])
        #expect(store.items.first?.isOwned == false)
        #expect(try filesInTheFolder().isEmpty)
    }

    @Test func whatSomeonePutsThereIsCopied() throws {
        AppSettings.shared.trayCopiesFiles = true
        defer { AppSettings.shared.trayCopiesFiles = false }
        store.add([file])
        #expect(store.items.first?.isOwned == true)
        #expect(try filesInTheFolder() == ["Screenshot.png"])
    }

    /// What the Tray makes of a list that says this path is its own.
    private func ownership(of url: URL) throws -> Bool? {
        let listed = TrayStore.Item(id: UUID(), url: url, isOwned: true, addedAt: .now)
        try JSONEncoder().encode([listed]).write(to: support.appendingPathComponent("tray.json"))
        let reopened = TrayStore(support: support)
        reopened.load()
        return reopened.items.first?.isOwned
    }

    @Test func aPathThroughALinkInTheFolderIsntTheTrays() throws {
        let outside = support.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: outside.appendingPathComponent("Kept.txt"))
        let link = store.folder.appendingPathComponent("Linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(try ownership(of: link.appendingPathComponent("Kept.txt")) == false)
    }

    @Test func aLinkInTheFolderIsntTheTrays() throws {
        let link = store.folder.appendingPathComponent("Shortcut.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(try ownership(of: link) == false)
    }

    @Test func aFileTheTrayMadeIsStillItsOwn() throws {
        store.add(data: Data("dropped".utf8), named: "Dropped.txt")
        #expect(try ownership(of: try #require(store.items.first?.url)) == true)
    }

    /// Links a scratch support folder's Tray to `target`.
    private func linkedSupport(to target: URL) throws -> URL {
        let linked = support.appendingPathComponent("Linked Support", isDirectory: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("Tray"), withDestinationURL: target)
        return linked
    }

    @Test func aLinkInPlaceOfTheFolderGoesAtLaunch() throws {
        let target = support.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let reopened = TrayStore(support: try linkedSupport(to: target))
        #expect((try reopened.folder.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == false)
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test func aLinkInPlaceOfTheFolderDoesntGetACopy() throws {
        AppSettings.shared.trayCopiesFiles = true
        defer { AppSettings.shared.trayCopiesFiles = false }
        let target = support.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: store.folder)
        try FileManager.default.createSymbolicLink(at: store.folder, withDestinationURL: target)
        store.add([file])
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        #expect(try filesInTheFolder() == ["Screenshot.png"])
    }

    /// The real `~/Library`, by other names. All this asks of it is whether those paths exist.
    @Test func otherSpellingsOfTheLibraryAreStillTheLibrary() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let onTheDataVolume = "/System/Volumes/Data" + home + "/Library/Preferences"
        #expect(FileManager.default.fileExists(atPath: onTheDataVolume))
        store.addFromScript([onTheDataVolume, home + "/LIBRARY/Preferences", home + "/lIbRaRy/preferences"].map { URL(fileURLWithPath: $0) })
        #expect(store.items.isEmpty)
    }

    @Test func whatsOutsideTheLibraryIsStillTaken() {
        store.addFromScript([file])
        #expect(store.items.count == 1)
        LiveActivityCenter.shared.dismissNotice()
    }
}
