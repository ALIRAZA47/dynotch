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

/// Tests and snapshots don't take the keyboard from whoever is at the Mac, or show on their screen.
@MainActor
struct ParkedCaptureTests {
    private let display = CaptureController.syntheticDisplay(id: 7, frame: CGRect(x: 0, y: 0, width: 400, height: 300), scale: 1)!

    init() {
        SnapshotRenderer.useScratchDefaults()
    }

    @Test func aParkedOverlayActsKeyButCantBecomeIt() {
        let window = CaptureOverlayWindow(display: display, editor: CaptureEditor(displays: [display], accent: .blue), isSnapshot: true)
        #expect(!window.canBecomeKey)
        #expect(window.isKeyWindow)
        window.close()
    }

    /// In real use it takes the keyboard, for the tools' keys.
    @Test func aRealOverlayCanBecomeKey() {
        let window = CaptureOverlayWindow(display: display, editor: CaptureEditor(displays: [display], accent: .blue))
        #expect(window.canBecomeKey)
        #expect(!window.isKeyWindow)
        window.close()
    }

    @Test func aParkedPinStaysOffScreenWhereverItWasTaken() {
        let output = CaptureOutput(image: display.image, scale: 1, pointSize: CGSize(width: 100, height: 80))
        let pin = PinnedCaptureWindow.pin(output, near: CGRect(x: -20_000, y: -70_000, width: 100, height: 80), isParked: true)
        #expect(!NSScreen.screens.contains { $0.frame.intersects(pin.frame) })
        #expect(!pin.isKeyWindow)
        pin.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                           characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!)
    }
}
