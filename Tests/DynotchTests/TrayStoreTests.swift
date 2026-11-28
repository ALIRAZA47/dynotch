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

    /// What the Tray makes of a list that says this path is its own, once it has looked at the path.
    private func ownership(of url: URL) async throws -> Bool? {
        let listed = TrayStore.Item(id: UUID(), url: url, isOwned: true, addedAt: .now)
        try JSONEncoder().encode([listed]).write(to: support.appendingPathComponent("tray.json"))
        let reopened = TrayStore(support: support)
        reopened.load()
        // Until it has, nothing on the list is the Tray's to trash.
        #expect(reopened.items.allSatisfy { !$0.isOwned })
        await reopened.inspection?.value
        return reopened.items.first?.isOwned
    }

    @Test func aPathThroughALinkInTheFolderIsntTheTrays() async throws {
        let outside = support.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: outside.appendingPathComponent("Kept.txt"))
        let link = store.folder.appendingPathComponent("Linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(try await ownership(of: link.appendingPathComponent("Kept.txt")) == false)
    }

    @Test func aLinkInTheFolderIsntTheTrays() async throws {
        let link = store.folder.appendingPathComponent("Shortcut.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(try await ownership(of: link) == false)
    }

    @Test func aFileTheTrayMadeIsStillItsOwn() async throws {
        store.add(data: Data("dropped".utf8), named: "Dropped.txt")
        #expect(try await ownership(of: try #require(store.items.first?.url)) == true)
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
    @Test func otherSpellingsOfTheLibraryAreStillTheLibrary() async {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let onTheDataVolume = "/System/Volumes/Data" + home + "/Library/Preferences"
        #expect(FileManager.default.fileExists(atPath: onTheDataVolume))
        await store.addFromScript([onTheDataVolume, home + "/LIBRARY/Preferences", home + "/lIbRaRy/preferences"].map { URL(fileURLWithPath: $0) }).value
        #expect(store.items.isEmpty)
    }

    @Test func whatsOutsideTheLibraryIsStillTaken() async {
        await store.addFromScript([file]).value
        #expect(store.items.count == 1)
        // Looked at on the way in, so the tile has its size without reading the disk.
        #expect(store.items.first?.info?.bytes == 7)
        LiveActivityCenter.shared.dismissNotice()
    }

    /// Off the main thread, so the paths aren't there yet when it returns.
    @Test func aScriptsFilesArriveAfterTheyveBeenLookedAt() async {
        let task = store.addFromScript([file, file, support.appendingPathComponent("Missing.txt")])
        #expect(store.items.isEmpty)
        await task.value
        #expect(store.items.map(\.url) == [file.resolvingSymlinksInPath().standardizedFileURL])
        LiveActivityCenter.shared.dismissNotice()
    }

    @Test func atMostTwentyFromOneLink() async throws {
        let many = try (0..<25).map { index -> URL in
            let url = support.appendingPathComponent("File \(index).txt")
            try Data("x".utf8).write(to: url)
            return url
        }
        await store.addFromScript(many).value
        #expect(store.items.count == 20)
        #expect(store.items.allSatisfy { !$0.isOwned })
        #expect(try filesInTheFolder().isEmpty)
        LiveActivityCenter.shared.dismissNotice()
    }

    // MARK: Looking at the files off the main thread

    private func writeList(_ urls: [URL]) throws {
        let listed = urls.map { TrayStore.Item(id: UUID(), url: $0, isOwned: false, addedAt: .now) }
        try JSONEncoder().encode(listed).write(to: support.appendingPathComponent("tray.json"))
    }

    @Test func aFileThatsGoneLeavesAfterTheLookAtLaunch() async throws {
        let gone = support.appendingPathComponent("Gone.txt")
        try writeList([file, gone])
        let reopened = TrayStore(support: support)
        reopened.load()
        // Up at once, as saved: whether they're there is read off the main thread.
        #expect(reopened.items.map(\.url) == [file, gone])
        await reopened.inspection?.value
        #expect(reopened.items.map(\.url) == [file])
    }

    @Test func sizesAreReadOnceAndKeptOnTheItem() async throws {
        try writeList([file])
        let reopened = TrayStore(support: support)
        reopened.load()
        #expect(reopened.items.first?.info == nil)
        await reopened.inspection?.value
        let info = try #require(reopened.items.first?.info)
        #expect(info.exists && info.bytes == 7 && info.detail != nil)
        // The file grows; the tile keeps what was read until the Tray looks again.
        try Data("a bigger picture".utf8).write(to: file)
        #expect(reopened.items.first?.info?.bytes == 7)
        await reopened.refreshFiles().value
        #expect(reopened.items.first?.info?.bytes == 16)
    }

    @Test func aFolderSaysSoAndHasNoSize() async throws {
        let folder = support.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store.add([folder])
        await store.inspection?.value
        let info = try #require(store.items.first?.info)
        #expect(info.detail == "Folder")
        #expect(info.bytes == nil)
    }

    @Test func movingAnItemForgetsItsSizeAndReadsItAgain() async throws {
        store.add([file])
        await store.inspection?.value
        #expect(store.items.first?.info?.bytes == 7)
        let other = support.appendingPathComponent("Other.txt")
        try Data("twelve bytes".utf8).write(to: other)
        store.relocate(try #require(store.items.first), to: other)
        #expect(store.items.first?.info == nil)
        await store.inspection?.value
        #expect(store.items.first?.info?.bytes == 12)
    }

    /// A look that comes back after the item has moved doesn't put the old file's size on it.
    @Test func aLookAtAnOldPathIsDropped() async throws {
        store.add([file])
        let look = store.inspection
        let other = support.appendingPathComponent("Other.txt")
        try Data("twelve bytes".utf8).write(to: other)
        store.relocate(try #require(store.items.first), to: other)
        await look?.value
        #expect(store.items.first?.info == nil || store.items.first?.info?.bytes == 12)
        await store.inspection?.value
        #expect(store.items.first?.info?.bytes == 12)
    }

    @Test func sizesAreNotSaved() async throws {
        store.add([file])
        await store.inspection?.value
        #expect(store.items.first?.info != nil)
        // A save with the size on the item.
        store.togglePin(try #require(store.items.first))
        let saved = try String(contentsOf: support.appendingPathComponent("tray.json"), encoding: .utf8)
        #expect(!saved.contains("info"))
        #expect(!saved.contains("fileSize"))
    }
}
