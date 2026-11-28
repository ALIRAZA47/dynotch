import CoreServices
import Foundation
import Testing
@testable import Dynotch

/// Each test has a store of its own on a folder of its own, so none of them can reach the real notes.
@MainActor
@Suite(.serialized)
final class NotesStoreTests {
    private let folder: URL
    private let file: URL
    private let store: NotesStore
    private let reads = ReadLog()
    private let trashed = TrashLog()

    init() async throws {
        SnapshotRenderer.useScratchDefaults()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("DynotchNotesTests-\(UUID().uuidString)", isDirectory: true)
        file = folder.appendingPathComponent("Groceries.md")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "Groceries\n- eggs".write(to: file, atomically: true, encoding: .utf8)
        // Never the real Trash: a folder inside the test's own, which the store doesn't list.
        let trashFolder = folder.appendingPathComponent("Trash", isDirectory: true)
        store = NotesStore(folder: folder, reader: { [reads] in try reads.read($0) }, trash: { [trashed] url in
            try FileManager.default.createDirectory(at: trashFolder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: trashFolder.appendingPathComponent(url.lastPathComponent))
            trashed.names.append(url.lastPathComponent)
        })
        await store.reload().value
    }

    deinit {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        try? FileManager.default.removeItem(at: folder)
    }

    private static let edited = "Groceries\n- eggs\n- milk"

    /// The old scratchpad's text and a chosen folder both come from the defaults, which anything can write.
    @Test func theScratchpadOnlyMovesIntoDynotchsOwnFolder() throws {
        let key = "notes.text"
        UserDefaults.dynotch.set("Left over", forKey: key)
        defer { UserDefaults.dynotch.removeObject(forKey: key) }
        let own = folder.appendingPathComponent("Own", isDirectory: true)
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)

        NotesStore(folder: folder, defaultFolder: own).migrateScratchpad()
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["Groceries.md", "Own"])
        #expect(UserDefaults.dynotch.string(forKey: key) == "Left over")

        NotesStore(folder: own).migrateScratchpad()
        #expect(try FileManager.default.contentsOfDirectory(atPath: own.path) == ["Left over.md"])
        #expect(UserDefaults.dynotch.string(forKey: key) == nil)
    }

    private var onDisk: String? { try? String(contentsOf: file, encoding: .utf8) }

    private func edit() throws {
        let note = try #require(store.notes.first)
        store.update(note.id, text: Self.edited)
    }

    private func setFolder(permissions: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: folder.path)
    }

    private func write(_ text: String, to name: String) throws {
        try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func note(named name: String) -> NotesStore.Note? {
        store.notes.first { $0.url.lastPathComponent == name }
    }

    @Test func aFolderThatCantBeListedKeepsItsNotes() async throws {
        try edit()
        try setFolder(permissions: 0o000)
        await store.reload().value
        try setFolder(permissions: 0o755)
        #expect(store.notes.map(\.text) == [Self.edited])
        store.saveAll()
    }

    @Test func aNoteThatCantBeReadKeepsItsEdits() async throws {
        try edit()
        // "café" in Latin-1, which isn't valid UTF-8.
        try (Data("caf".utf8) + [0xE9]).write(to: file)
        await store.reload().value
        #expect(store.notes.map(\.text) == [Self.edited])
        store.saveAll()
    }

    @Test func aNoteDeletedElsewhereKeepsItsEdits() async throws {
        try edit()
        try FileManager.default.removeItem(at: file)
        await store.reload().value
        #expect(store.notes.map(\.text) == [Self.edited])
        store.saveAll()
        #expect(onDisk == Self.edited)
    }

    @Test func aNoteDeletedElsewhereWithNoEditsGoes() async throws {
        try FileManager.default.removeItem(at: file)
        await store.reload().value
        #expect(store.notes.map(\.text) == [""])
    }

    @Test func aFailedSaveIsWrittenOutOnQuit() throws {
        try edit()
        try setFolder(permissions: 0o555)
        store.saveAll()
        #expect(store.saveFailed)
        try setFolder(permissions: 0o755)
        store.saveAll()
        #expect(onDisk == Self.edited)
        #expect(!store.saveFailed)
    }

    @Test func aFailedSaveIsTriedAgain() async throws {
        store.retryDelay = .milliseconds(50)
        try edit()
        try setFolder(permissions: 0o555)
        store.saveAll()
        try setFolder(permissions: 0o755)
        for _ in 0..<100 where onDisk != Self.edited {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(onDisk == Self.edited)
        #expect(!store.saveFailed)
    }

    // MARK: Reading only what changed

    @Test func aReloadReadsOnlyWhatChanged() async throws {
        #expect(reads.names == ["Groceries.md"])
        try write("Ideas", to: "Ideas.md")
        await store.reload().value
        #expect(reads.names == ["Groceries.md", "Ideas.md"])

        await store.reload().value
        await store.reload().value
        #expect(reads.names == ["Groceries.md", "Ideas.md"])

        try write("Ideas\n- a notch for the cat", to: "Ideas.md")
        await store.reload().value
        #expect(reads.names == ["Groceries.md", "Ideas.md", "Ideas.md"])
        #expect(note(named: "Ideas.md")?.text == "Ideas\n- a notch for the cat")
    }

    @Test func anEditElsewhereShowsAndUnsavedTextHereStays() async throws {
        try write("Ideas", to: "Ideas.md")
        await store.reload().value
        try edit()

        try write("Ideas\n- from the other Mac", to: "Ideas.md")
        // The note being edited changes on disk too: what's typed here, and not saved yet, wins.
        try "Groceries\n- bread, from elsewhere".write(to: file, atomically: true, encoding: .utf8)
        await store.reload().value
        #expect(note(named: "Ideas.md")?.text == "Ideas\n- from the other Mac")
        #expect(note(named: "Groceries.md")?.text == Self.edited)

        store.saveAll()
        #expect(onDisk == Self.edited)
    }

    @Test func aSaveHereReadsNothingAgain() async throws {
        let id = try #require(store.notes.first?.id)
        try edit()
        store.saveAll()
        let before = reads.names
        await store.reload().value
        #expect(reads.names == before)
        #expect(store.notes.map(\.text) == [Self.edited])

        // A new first line renames the file; that isn't read again either.
        store.update(id, text: "Shopping\n- eggs")
        store.saveAll()
        await store.reload().value
        #expect(reads.names == before)
        #expect(store.notes.map(\.id) == [id])
        #expect(store.notes.map(\.url.lastPathComponent) == ["Shopping.md"])
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// A rename here while the folder is being read: the listing taken before it mustn't bring back the
    /// old name as a new note and drop the renamed one.
    @Test func aSaveWhileTheFolderIsReadIsntUndone() async throws {
        let id = try #require(store.notes.first?.id)
        try write("Ideas", to: "Ideas.md")
        reads.hold("Ideas.md")
        let reloading = store.reload()
        for _ in 0..<200 where !reads.isHolding {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(reads.isHolding)

        store.update(id, text: "Shopping\n- eggs")
        store.saveAll()
        reads.release()
        await reloading.value
        await store.reload().value

        #expect(store.notes.first { $0.id == id }?.url.lastPathComponent == "Shopping.md")
        #expect(Set(store.notes.map(\.url.lastPathComponent)) == ["Shopping.md", "Ideas.md"])
    }

    @Test func aFileTooBigIsLeftOutAndNeverWrittenBack() async throws {
        let big = folder.appendingPathComponent("Big.md")
        try Data(repeating: UInt8(ascii: "a"), count: NotesStore.maxFileBytes + 1).write(to: big)
        await store.reload().value
        #expect(note(named: "Big.md") == nil)
        #expect(!reads.names.contains("Big.md"))
        store.saveAll()
        let size = try big.resourceValues(forKeys: [.fileSizeKey]).fileSize
        #expect(size == NotesStore.maxFileBytes + 1)
    }

    // MARK: Events

    @Test func eventsInsideSubfoldersOrForHiddenFilesDontReload() async throws {
        let path = folder.path
        let scans = store.scans
        #expect(!store.handleEvents(["\(path)/Sub/Nested.md", "\(path)/.obsidian/workspace.json", "\(path)/.Hidden.md",
                                     "\(path)/notes.txt", "\(path)/Sub", path, "/elsewhere/Groceries.md"],
                                    flags: Array(repeating: 0, count: 7)))
        try await Task.sleep(for: .milliseconds(500))
        #expect(store.scans == scans)
    }

    @Test func eventsForNotesInTheFolderReload() async throws {
        let real = try #require(realpath(folder.path, nil))
        let realPath = String(cString: real)
        free(real)
        // Events name the real path, /private/var for a folder in /var.
        #expect(store.handleEvents(["\(realPath)/Ideas.MD"], flags: [0]))
        #expect(store.handleEvents(["\(folder.path)/Groceries.md"], flags: [0]))
        // Events were dropped: look at everything.
        #expect(store.handleEvents(["\(folder.path)/Sub/Nested.md"],
                                   flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)]))
        let scans = store.scans
        try write("Ideas", to: "Ideas.md")
        for _ in 0..<100 where note(named: "Ideas.md") == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.scans > scans)
        #expect(note(named: "Ideas.md")?.text == "Ideas")
    }

    // MARK: Empty notes

    @Test func anEmptyNoteMadeHereIsRemoved() async throws {
        let groceries = try #require(store.notes.first?.id)
        store.newNote()
        let id = try #require(store.currentID)
        store.update(id, text: "Call the vet")
        store.saveAll()
        let made = folder.appendingPathComponent("Call the vet.md")
        #expect(FileManager.default.fileExists(atPath: made.path))
        store.update(id, text: "")
        store.saveAll()

        store.select(groceries)
        #expect(!FileManager.default.fileExists(atPath: made.path))
        #expect(trashed.names.isEmpty)
        #expect(store.notes.map(\.id) == [groceries])
    }

    @Test func anEmptyFileFromElsewhereGoesToTheTrash() async throws {
        let groceries = try #require(store.notes.first?.id)
        try write("", to: "Empty.md")
        await store.reload().value
        let empty = try #require(note(named: "Empty.md")?.id)

        store.select(empty)
        store.select(groceries)
        #expect(trashed.names == ["Empty.md"])
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("Empty.md").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Trash/Empty.md").path))
    }
}

/// The files a store read, and a way to hold one read until the test lets it go. The read waits on
/// the store's own queue, not on a task thread.
final class ReadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var held: String?
    private var holding = false
    private let gate = DispatchSemaphore(value: 0)

    func read(_ url: URL) throws -> Data {
        let wait = lock.withLock {
            log.append(url.lastPathComponent)
            holding = held == url.lastPathComponent
            return holding
        }
        if wait { _ = gate.wait(timeout: .now() + 10) }
        return try Data(contentsOf: url)
    }

    var names: [String] { lock.withLock { log } }
    var isHolding: Bool { lock.withLock { holding } }
    func hold(_ name: String) { lock.withLock { held = name } }

    func release() {
        lock.withLock { held = nil }
        gate.signal()
    }
}

/// What the store sent to the Trash. Only used on the main thread, where the store calls it.
final class TrashLog {
    var names: [String] = []
}
