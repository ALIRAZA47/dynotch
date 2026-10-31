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

    init() throws {
        SnapshotRenderer.useScratchDefaults()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("DynotchNotesTests-\(UUID().uuidString)", isDirectory: true)
        file = folder.appendingPathComponent("Groceries.md")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "Groceries\n- eggs".write(to: file, atomically: true, encoding: .utf8)
        store = NotesStore(folder: folder)
        store.reload()
    }

    deinit {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        try? FileManager.default.removeItem(at: folder)
    }

    private static let edited = "Groceries\n- eggs\n- milk"

    private var onDisk: String? { try? String(contentsOf: file, encoding: .utf8) }

    private func edit() throws {
        let note = try #require(store.notes.first)
        store.update(note.id, text: Self.edited)
    }

    private func setFolder(permissions: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: folder.path)
    }

    @Test func aFolderThatCantBeListedKeepsItsNotes() throws {
        try edit()
        try setFolder(permissions: 0o000)
        store.reload()
        try setFolder(permissions: 0o755)
        #expect(store.notes.map(\.text) == [Self.edited])
        store.saveAll()
    }

    @Test func aNoteThatCantBeReadKeepsItsEdits() throws {
        try edit()
        // "café" in Latin-1, which isn't valid UTF-8.
        try (Data("caf".utf8) + [0xE9]).write(to: file)
        store.reload()
        #expect(store.notes.map(\.text) == [Self.edited])
        store.saveAll()
    }

    @Test func aNoteDeletedElsewhereKeepsItsEdits() throws {
        try edit()
        try FileManager.default.removeItem(at: file)
        store.reload()
        #expect(store.notes.map(\.text) == [Self.edited])
        store.saveAll()
        #expect(onDisk == Self.edited)
    }

    @Test func aNoteDeletedElsewhereWithNoEditsGoes() throws {
        try FileManager.default.removeItem(at: file)
        store.reload()
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
}
