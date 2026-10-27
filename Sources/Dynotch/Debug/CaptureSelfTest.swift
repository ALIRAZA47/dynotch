import AppKit
import SwiftUI

/// `Dynotch --capture-self-test <folder>` drives the capture editor with synthesized events over a
/// made-up display parked off screen: selects, moves and resizes a region, draws with every tool,
/// types a text mark, undoes and redoes from the keyboard and the toolbar, then copies to a
/// pasteboard of its own, saves into the folder and pins. It prints a line per check and leaves
/// the finished capture in the folder.
@MainActor
enum CaptureSelfTest {
    private static var failures: [String] = []

    static func run(into folder: URL) -> Bool {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        failures = []
        let controller = CaptureController.shared
        controller.placesOverlaysOffScreen = true
        controller.pasteboard = NSPasteboard(name: NSPasteboard.Name("app.dynotch.capture-self-test"))
        controller.saveFolderOverride = folder
        guard let display = CaptureController.syntheticDisplay(id: 7, frame: CGRect(x: 0, y: 0, width: 1280, height: 800), scale: 2) else {
            print("FAIL no synthetic display")
            return false
        }

        controller.beginTest(displays: [display])
        guard let editor = controller.editor, let window = controller.overlays.first else {
            print("FAIL the editor didn't open")
            return false
        }
        settle(0.8)
        check(editor.selection == nil, "nothing is selected at first")

        // Selecting, moving and resizing.
        drag(window, from: CGPoint(x: 200, y: 150), to: CGPoint(x: 900, y: 600))
        check(editor.selection == CGRect(x: 200, y: 150, width: 700, height: 450), "dragging selects the region")
        click(window, at: CGPoint(x: 1100, y: 720))
        check(editor.selection == CGRect(x: 0, y: 0, width: 1280, height: 800), "a click selects the whole display")
        drag(window, from: CGPoint(x: 200, y: 150), to: CGPoint(x: 900, y: 600))
        drag(window, from: CGPoint(x: 500, y: 400), to: CGPoint(x: 530, y: 420))
        check(editor.selection == CGRect(x: 230, y: 170, width: 700, height: 450), "dragging inside moves the selection")
        drag(window, from: CGPoint(x: 930, y: 620), to: CGPoint(x: 980, y: 660))
        check(editor.selection == CGRect(x: 230, y: 170, width: 750, height: 490), "the bottom-right handle resizes it")
        drag(window, from: CGPoint(x: 230, y: 415), to: CGPoint(x: 250, y: 415))
        check(editor.selection == CGRect(x: 250, y: 170, width: 730, height: 490), "the left handle resizes it")
        check(editor.toolbarFrame(on: display.id)?.minY == 670, "the toolbar sits under the selection")
        check(editor.controlFrames["Undo"] != nil, "the toolbar reported its controls")

        // The tools, by their keys.
        key("a", editor); check(editor.tool == .arrow, "A picks the arrow")
        drag(window, from: CGPoint(x: 300, y: 250), to: CGPoint(x: 500, y: 350))
        check(editor.document.annotations.last?.kind == .arrow(from: CGPoint(x: 300, y: 250), to: CGPoint(x: 500, y: 350)), "the arrow is drawn")
        key("r", editor)
        drag(window, from: CGPoint(x: 320, y: 300), to: CGPoint(x: 600, y: 420))
        check(editor.document.annotations.last?.kind == .rectangle(CGRect(x: 320, y: 300, width: 280, height: 120)), "the rectangle is drawn")
        key("c", editor)
        drag(window, from: CGPoint(x: 700, y: 250), to: CGPoint(x: 800, y: 350))
        check(editor.document.annotations.last?.kind == .ellipse(CGRect(x: 700, y: 250, width: 100, height: 100)), "the ellipse is drawn")
        key("l", editor)
        drag(window, from: CGPoint(x: 300, y: 500), to: CGPoint(x: 600, y: 520))
        check(editor.document.annotations.last?.kind == .line(from: CGPoint(x: 300, y: 500), to: CGPoint(x: 600, y: 520)), "the line is drawn")
        key("p", editor)
        drag(window, from: CGPoint(x: 650, y: 500), to: CGPoint(x: 850, y: 560), steps: 12)
        if case .pencil(let points)? = editor.document.annotations.last?.kind, points.count >= 10 {
            check(true, "the pencil follows the pointer (\(points.count) points)")
        } else {
            check(false, "the pencil follows the pointer")
        }
        key("m", editor)
        drag(window, from: CGPoint(x: 300, y: 450), to: CGPoint(x: 600, y: 450), steps: 6)
        if case .marker? = editor.document.annotations.last?.kind { check(true, "the marker is drawn") } else { check(false, "the marker is drawn") }
        key("b", editor)
        drag(window, from: CGPoint(x: 400, y: 350), to: CGPoint(x: 560, y: 420))
        check(editor.document.annotations.last?.kind == .blur(CGRect(x: 400, y: 350, width: 160, height: 70)), "the blur is placed")
        key("n", editor)
        click(window, at: CGPoint(x: 700, y: 450))
        click(window, at: CGPoint(x: 740, y: 450))
        check(editor.document.annotations.last?.kind == .counter(center: CGPoint(x: 740, y: 450), number: 2), "counters count up")
        key("t", editor)
        click(window, at: CGPoint(x: 350, y: 560))
        settle(0.5)
        check(editor.isEditingText, "T then a click opens the text field")
        type("Hi", into: window)
        settle(0.3)
        if editor.editingText != "Hi" {
            // The off-screen window can't take the keyboard in every setup; the field's binding still can.
            print("note typing didn't reach the field (got \"\(editor.editingText)\"), setting the text instead")
            editor.editingText = "Hi"
        }
        key("\n", editor, keyCode: 36)
        check(!editor.isEditingText && editor.document.annotations.last?.kind == .text(origin: CGPoint(x: 350, y: 560), string: "Hi"),
              "Return commits the text")
        let drawn = editor.document.annotations.count
        check(drawn == 10, "ten marks were made (\(drawn))")

        // Undo and redo, from the keyboard and the toolbar.
        key("z", editor, flags: .command)
        check(editor.document.annotations.count == 9, "⌘Z undoes")
        key("z", editor, flags: [.command, .shift])
        check(editor.document.annotations.count == 10, "⇧⌘Z redoes")
        press("Undo", editor, window)
        check(editor.document.annotations.count == 9, "the Undo button undoes")
        press("Redo", editor, window)
        check(editor.document.annotations.count == 10, "the Redo button redoes")
        press("Blue", editor, window)
        check(editor.color == .blue, "a swatch picks the color")
        press("Pencil", editor, window)
        check(editor.tool == .pencil, "a tool button picks the tool")
        if let slider = editor.controlFrames["Width"] {
            drag(window, from: CGPoint(x: slider.minX + 2, y: slider.midY), to: CGPoint(x: slider.maxX - 2, y: slider.midY))
            check(editor.width == 16, "the slider goes to 16 (\(Int(editor.width)))")
            drag(window, from: CGPoint(x: slider.maxX - 2, y: slider.midY), to: CGPoint(x: slider.minX + 2, y: slider.midY))
            check(editor.width == 1, "and back to 1 (\(Int(editor.width)))")
            editor.width = 4
        } else {
            check(false, "the slider reported its frame")
        }
        key("s", editor)
        check(editor.tool == nil, "S goes back to selecting")

        // Rendering: the selection at the display's scale, the blur really changed.
        guard let output = editor.render() else {
            check(false, "the capture renders")
            return finish()
        }
        check(output.image.width == 1460 && output.image.height == 980, "the image is the selection at 2x (\(output.image.width) × \(output.image.height))")
        if let url = ScreenshotFile.save(output.image, scale: output.scale, in: folder) {
            check(url.lastPathComponent.hasPrefix("Screenshot ") && url.pathExtension == "png", "saved as \(url.lastPathComponent)")
            check(getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0, "the file is tagged as a screen capture")
            let kept = folder.appendingPathComponent("capture-self-test.png")
            try? FileManager.default.removeItem(at: kept)
            try? FileManager.default.moveItem(at: url, to: kept)
        } else {
            check(false, "the capture saves")
        }
        check(pixelsDiffer(output.image, display.image, at: CGPoint(x: 480, y: 385), scale: 2, selection: editor.selection!), "the blur changed the pixels")

        // The actions close the editor, from the toolbar's buttons.
        press("Copy", editor, window)
        settle(0.3)
        check(!controller.isActive, "the Copy button copies and closes the editor")
        check(controller.pasteboard.data(forType: .png) != nil && controller.pasteboard.data(forType: .tiff) != nil, "PNG and TIFF are on the pasteboard")

        controller.beginTest(displays: [display])
        guard let second = controller.editor, let secondWindow = controller.overlays.first else {
            check(false, "the editor opens again")
            return finish()
        }
        settle(0.5)
        drag(secondWindow, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 400, y: 300))
        press("Save", second, secondWindow)
        settle(0.3)
        let saved = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { $0.hasPrefix("Screenshot ") } ?? []
        check(!controller.isActive && saved.count == 1, "Save writes the file and closes (\(saved.count) saved)")
        saved.forEach { try? FileManager.default.removeItem(at: folder.appendingPathComponent($0)) }

        controller.beginTest(displays: [display])
        guard let third = controller.editor, let thirdWindow = controller.overlays.first else {
            check(false, "the editor opens a third time")
            return finish()
        }
        settle(0.5)
        drag(thirdWindow, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 400, y: 300))
        press("Pin", third, thirdWindow)
        let pins = PinnedCaptureWindow.all
        pins.forEach { $0.setFrameOrigin(NSPoint(x: -30_000, y: -70_000)) }
        settle(0.3)
        check(!controller.isActive && pins.count == 1, "Pin opens a pinned window and closes the editor")
        check(pins.first?.frame.size == CGSize(width: 300, height: 200), "the pinned window is the capture's point size")
        pins.first?.keyDown(with: keyEvent("\u{1b}", keyCode: 53, flags: []))
        check(PinnedCaptureWindow.all.isEmpty, "Esc closes the pinned window")

        controller.beginTest(displays: [display])
        settle(0.3)
        key("\u{1b}", controller.editor!, keyCode: 53)
        check(!controller.isActive, "Esc cancels the capture")
        return finish()
    }

    private static func finish() -> Bool {
        if failures.isEmpty {
            print("Capture self-test passed")
        } else {
            print("Capture self-test: \(failures.count) failed: \(failures.joined(separator: "; "))")
        }
        return failures.isEmpty
    }

    private static func check(_ condition: Bool, _ what: String) {
        print((condition ? "ok   " : "FAIL ") + what)
        if !condition { failures.append(what) }
    }

    private static func settle(_ seconds: TimeInterval) {
        RunLoop.main.run(until: .now + seconds)
    }

    // MARK: Events

    /// A mouse event at a point in the display's top-left points.
    private static func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: point.x, y: window.frame.height - point.y), modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
    }

    private static func send(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) {
        guard let event = mouseEvent(type, at: point, in: window) else { return }
        window.sendEvent(event)
        settle(0.03)
    }

    private static func click(_ window: NSWindow, at point: CGPoint) {
        send(.mouseMoved, at: point, in: window)
        send(.leftMouseDown, at: point, in: window)
        send(.leftMouseUp, at: point, in: window)
    }

    private static func drag(_ window: NSWindow, from: CGPoint, to: CGPoint, steps: Int = 4) {
        send(.mouseMoved, at: from, in: window)
        send(.leftMouseDown, at: from, in: window)
        for step in 1...steps {
            let fraction = CGFloat(step) / CGFloat(steps)
            send(.leftMouseDragged, at: CGPoint(x: from.x + (to.x - from.x) * fraction, y: from.y + (to.y - from.y) * fraction), in: window)
        }
        send(.leftMouseUp, at: to, in: window)
    }

    private static func press(_ control: String, _ editor: CaptureEditor, _ window: NSWindow) {
        guard let frame = editor.controlFrames[control] else {
            check(false, "the \(control) control reported its frame")
            return
        }
        click(window, at: CGPoint(x: frame.midX, y: frame.midY))
        settle(0.1)
    }

    private static func keyEvent(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: keyCode)!
    }

    /// A key press as the editor's monitor sees it.
    private static func key(_ characters: String, _ editor: CaptureEditor, keyCode: UInt16 = 0, flags: NSEvent.ModifierFlags = []) {
        _ = editor.handleKey(keyEvent(characters, keyCode: keyCode, flags: flags))
        settle(0.05)
    }

    /// Typing into whatever has the keyboard in the window. The snapshots use it too.
    static func type(_ text: String, into window: NSWindow) {
        for character in text {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, characters: String(character),
                                         charactersIgnoringModifiers: String(character).lowercased(), isARepeat: false, keyCode: 0)!
            window.sendEvent(event)
            settle(0.03)
        }
    }

    /// Whether the rendered pixel at a display point differs from the frozen one under it.
    private static func pixelsDiffer(_ output: CGImage, _ source: CGImage, at point: CGPoint, scale: CGFloat, selection: CGRect) -> Bool {
        func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8]? {
            guard x >= 0, y >= 0, x < image.width, y < image.height, let data = image.dataProvider?.data as Data? else { return nil }
            let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
            return Array(data[offset..<offset + 3])
        }
        let sourcePixel = pixel(source, x: Int(point.x * scale), y: Int(point.y * scale))
        let outputPixel = pixel(output, x: Int((point.x - selection.minX) * scale), y: Int((point.y - selection.minY) * scale))
        guard let sourcePixel, let outputPixel else { return false }
        return sourcePixel != outputPixel
    }
}
