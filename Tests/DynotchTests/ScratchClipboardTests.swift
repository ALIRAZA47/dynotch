import AppKit
import Foundation
import Testing
@testable import Dynotch

/// Nothing but the real app may reach what the user copied. A live check once clicked a real clip
/// card and overwrote the clipboard, so this is built in rather than left to care.
@MainActor
struct ScratchClipboardTests {
    init() {
        SnapshotRenderer.useScratchDefaults()
    }

    @Test func aRunOnScratchDefaultsHasAClipboardOfItsOwn() {
        #expect(NSPasteboard.dynotch.name != NSPasteboard.general.name)
    }

    /// The store the real views click, which is what did it.
    @Test func theRealStoreCopiesToTheScratchClipboard() {
        ClipboardStore.shared.copy(ClipboardStore.Clip(text: "only on the scratch clipboard"))
        #expect(NSPasteboard.dynotch.string(forType: .string) == "only on the scratch clipboard")
    }

    /// So it stays that way. This reads the source, and never the clipboard: `.general` is named once,
    /// where `NSPasteboard.dynotch` defaults to it.
    @Test func onlyOnePlaceNamesTheRealClipboard() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Dynotch")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var named: [String] = []
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n") {
                let isReal = line.contains("NSPasteboard.general") || line.contains("pasteboard: .general")
                    || line.contains("NSPasteboard = .general")
                if isReal { named.append("\(file.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))") }
            }
        }
        #expect(named == ["AppSettings.swift: nonisolated(unsafe) static var dynotch: NSPasteboard = .general"])
    }
}
