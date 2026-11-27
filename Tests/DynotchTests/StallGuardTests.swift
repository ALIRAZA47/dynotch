import AppKit
import Combine
import Testing
@testable import Dynotch

/// When a drag reads the drag pasteboard. Nothing here touches a real pasteboard: the reader is a closure.
@MainActor
struct DragGateTests {
    private let reach = CGRect(x: 700, y: 1000, width: 340, height: 110)
    private let inside = CGPoint(x: 860, y: 1050)
    private let outside = CGPoint(x: 200, y: 300)

    private func opens(at point: CGPoint, isEnabled: Bool = true, isDraggingOut: Bool = false, carries: Bool = true) -> (Bool, Int) {
        var asked = 0
        let opens = NotchWindowController.opensTrayOnDrag(at: point, reach: reach, isEnabled: isEnabled, isDraggingOut: isDraggingOut) {
            asked += 1
            return carries
        }
        return (opens, asked)
    }

    @Test func withTheSettingOffThePasteboardIsntAsked() {
        let (opens, asked) = opens(at: inside, isEnabled: false)
        #expect(!opens)
        #expect(asked == 0)
    }

    @Test func farFromTheNotchThePasteboardIsntAsked() {
        let (opens, asked) = opens(at: outside)
        #expect(!opens)
        #expect(asked == 0)
    }

    @Test func draggingOutOfTheNotchIsntAskedAbout() {
        let (opens, asked) = opens(at: inside, isDraggingOut: true)
        #expect(!opens)
        #expect(asked == 0)
    }

    @Test func nearTheNotchWithTheSettingOnItsAskedOnce() {
        let files = opens(at: inside)
        #expect(files == (true, 1))
        let text = opens(at: inside, carries: false)
        #expect(text == (false, 1))
    }
}

/// "Is it a file drag" is worked out once per drag, as "does it hold images" is.
struct FileDragCheckTests {
    @Test func theTypesAreReadOncePerDrag() {
        var check = FileDragCheck()
        var reads = 0
        for _ in 0..<100 {
            let carries = check.carriesFiles(changeCount: 4) {
                reads += 1
                return [.fileURL]
            }
            #expect(carries)
        }
        #expect(reads == 1)
    }

    @Test func aNewDragIsReadAgain() {
        var check = FileDragCheck()
        var reads = 0
        #expect(check.carriesFiles(changeCount: 4) { reads += 1; return [.fileURL] })
        #expect(!check.carriesFiles(changeCount: 5) { reads += 1; return [.string] })
        #expect(!check.carriesFiles(changeCount: 5) { reads += 1; return [.fileURL] })
        #expect(reads == 2)
    }

    @Test func filesAndPicturesAreWhatTheTrayTakes() {
        #expect(FileDragCheck.accepts([.fileURL]))
        #expect(FileDragCheck.accepts([.string, .png]))
        #expect(FileDragCheck.accepts([.tiff]))
        #expect(!FileDragCheck.accepts([.string, .URL, .rtf]))
        #expect(!FileDragCheck.accepts([]))
    }
}

/// Stands in for the notch's manager, so no test takes the real keyboard's Esc.
@MainActor
private final class EscapeStandIn: EscapeHolding {
    private(set) var action: (@MainActor () -> Void)?
    private(set) var holds = 0
    private(set) var releases = 0

    var isHeld: Bool { action != nil }

    func holdEscape(_ action: @escaping @MainActor () -> Void) {
        holds += 1
        self.action = action
    }

    func releaseEscape() {
        releases += 1
        action = nil
    }

    func press() {
        action?()
    }
}

/// The capture overlay's ways out, on a made-up display parked off screen. Nothing reads the screen,
/// the keyboard or the clipboard.
@MainActor
@Suite(.serialized)
struct CaptureWaysOutTests {
    private let display = CaptureController.syntheticDisplay(id: 7, frame: CGRect(x: 0, y: 0, width: 480, height: 360), scale: 1)!

    /// The shared controller with a stand-in for Esc and for the screen going quiet, put back after.
    private func withCapture(idleLimit: TimeInterval = 120,
                             _ body: (CaptureController, CaptureEditor, EscapeStandIn, PassthroughSubject<Bool, Never>) async throws -> Void)
        async throws {
        SnapshotRenderer.useScratchDefaults()
        let controller = CaptureController.shared
        let escape = EscapeStandIn()
        let quiet = PassthroughSubject<Bool, Never>()
        let saved = (controller.placesOverlaysOffScreen, controller.escapeHolder, controller.idleLimit, controller.quietChanges)
        controller.placesOverlaysOffScreen = true
        controller.escapeHolder = escape
        controller.idleLimit = idleLimit
        controller.quietChanges = quiet.eraseToAnyPublisher()
        defer {
            controller.cancel()
            (controller.placesOverlaysOffScreen, controller.escapeHolder, controller.idleLimit, controller.quietChanges) = saved
        }
        controller.beginTest(displays: [display])
        let editor = try #require(controller.editor)
        try await body(controller, editor, escape, quiet)
    }

    @Test func escIsHeldForTheOverlayAndCancelsIt() async throws {
        try await withCapture { controller, _, escape, _ in
            #expect(escape.holds == 1 && escape.isHeld)
            escape.press()
            #expect(!controller.isActive)
            #expect(controller.overlays.isEmpty)
            #expect(escape.releases == 1 && !escape.isHeld)
        }
    }

    @Test func escWhileTypingAMarkDropsTheMarkFirst() async throws {
        try await withCapture { controller, editor, escape, _ in
            editor.stage(selection: CGRect(x: 40, y: 40, width: 300, height: 200), on: display.id)
            editor.tool = .text
            editor.mouseDown(at: CGPoint(x: 100, y: 100), on: display.id)
            try #require(editor.isEditingText)
            escape.press()
            #expect(!editor.isEditingText)
            #expect(controller.isActive)
            escape.press()
            #expect(!controller.isActive)
        }
    }

    @Test func cancellingGivesEscBackOnce() async throws {
        try await withCapture { controller, _, escape, _ in
            controller.cancel()
            #expect(escape.releases == 1 && !escape.isHeld)
            controller.cancel()
            #expect(escape.releases == 1)
        }
    }

    @Test func theScreenGoingQuietCancelsIt() async throws {
        try await withCapture { controller, _, escape, quiet in
            quiet.send(false)
            #expect(controller.isActive)
            quiet.send(true)
            #expect(!controller.isActive)
            #expect(escape.releases == 1)
        }
    }

    @Test func theDisplaysChangingCancelsIt() async throws {
        try await withCapture { controller, _, escape, _ in
            NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
            #expect(!controller.isActive)
            #expect(escape.releases == 1)
        }
    }

    @Test func aClosedCaptureStopsListening() async throws {
        try await withCapture { controller, _, escape, quiet in
            controller.cancel()
            controller.beginTest(displays: [display])
            try #require(controller.isActive)
            controller.cancel()
            NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
            quiet.send(true)
            #expect(escape.holds == 2 && escape.releases == 2)
        }
    }

    @Test func nobodyThereForTheLimitCancelsIt() async throws {
        try await withCapture(idleLimit: 0.2) { controller, _, escape, _ in
            try await Task.sleep(for: .milliseconds(800))
            #expect(!controller.isActive)
            #expect(escape.releases == 1)
        }
    }

    @Test func aSelectionKeepsItUp() async throws {
        try await withCapture(idleLimit: 0.2) { controller, editor, _, _ in
            editor.stage(selection: CGRect(x: 40, y: 40, width: 300, height: 200), on: display.id)
            try await Task.sleep(for: .milliseconds(800))
            #expect(controller.isActive)
        }
    }

    @Test func thePointerMovingKeepsItUp() async throws {
        try await withCapture(idleLimit: 1.5) { controller, _, _, _ in
            let overlay = try #require(controller.overlays.first)
            for _ in 0..<20 {
                overlay.onActivity?()
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(controller.isActive)
        }
    }

    @Test func idleIsNothingSelectedForTheWholeLimit() {
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(CaptureController.isIdle(hasSelection: false, lastActivity: start, now: start.addingTimeInterval(120), limit: 120))
        #expect(!CaptureController.isIdle(hasSelection: false, lastActivity: start, now: start.addingTimeInterval(119), limit: 120))
        #expect(!CaptureController.isIdle(hasSelection: true, lastActivity: start, now: start.addingTimeInterval(600), limit: 120))
    }
}
