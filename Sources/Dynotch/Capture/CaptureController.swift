import AppKit
import Combine
import ScreenCaptureKit
import SwiftUI

/// A frozen display: its place on the desktop, its scale and what was on it.
struct CaptureDisplay: Identifiable {
    let id: CGDirectDisplayID
    /// The display's frame on the desktop, in AppKit's coordinates.
    let frame: CGRect
    let scale: CGFloat
    /// The display's pixels, top row first.
    let image: CGImage

    var size: CGSize { frame.size }
}

/// Takes a screenshot the way Flameshot does: freezes every display under a dimmed overlay, lets
/// the user drag out a region and mark it up, then copies, saves or pins the result.
@MainActor
final class CaptureController: ObservableObject {
    static let shared = CaptureController()

    /// Whether macOS lets Dynotch record the screen. Looked up when a capture starts and after asking.
    @Published private(set) var hasAccess = CGPreflightScreenCaptureAccess()
    /// macOS asks once; after that the Permissions page opens System Settings instead.
    @Published private(set) var hasAsked = UserDefaults.standard.bool(forKey: "askedForScreenRecording")

    private(set) var editor: CaptureEditor?
    private(set) var overlays: [CaptureOverlayWindow] = []
    private var keyMonitor: Any?
    private var accessPoll: Poll?
    private var isFreezing = false
    private var shutter: NSSound?
    /// Tests park the overlays off screen, so a self-test never covers the desktop.
    var placesOverlaysOffScreen = false
    /// Where Copy puts the capture. A test uses a pasteboard of its own, leaving the clipboard alone.
    var pasteboard = NSPasteboard.general
    /// Where Save puts the file instead of the Screenshot app's folder, for tests.
    var saveFolderOverride: URL?

    private static let shutterPath = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif"

    private init() {}

    var isActive: Bool { editor != nil }

    /// Freezes the displays and opens the editor. Without Screen Recording access, asks for it and says so in the notch.
    func begin() {
        guard editor == nil, !isFreezing else { return }
        refreshAccess()
        guard hasAccess else {
            requestAccess()
            LiveActivityCenter.shared.post(LiveNotice(key: "capture", symbol: "rectangle.dashed.badge.record", tint: .orange,
                                                      text: "Screen Recording",
                                                      detail: "Capture needs it: allow Dynotch in System Settings → Privacy & Security"), for: 5)
            return
        }
        isFreezing = true
        Task {
            do {
                let displays = try await freeze()
                show(displays)
            } catch {
                NSLog("Dynotch: couldn't capture the screen: %@", error.localizedDescription)
                LiveActivityCenter.shared.post(LiveNotice(key: "capture", symbol: "rectangle.dashed.badge.record", tint: .orange,
                                                          text: "Capture failed", detail: "The screen couldn't be read"), for: 3)
            }
            isFreezing = false
        }
    }

    /// `--capture-test`: the editor over a made-up picture of each display, which needs no permission.
    /// A test can hand in displays of its own.
    func beginTest(displays: [CaptureDisplay]? = nil) {
        guard editor == nil else { return }
        show(displays ?? NSScreen.screens.compactMap { screen in
            Self.syntheticDisplay(id: screen.displayID, frame: screen.frame, scale: screen.backingScaleFactor)
        })
    }

    func cancel() {
        tearDown()
    }

    // MARK: Permission

    func refreshAccess() {
        let granted = CGPreflightScreenCaptureAccess()
        if granted != hasAccess { hasAccess = granted }
    }

    /// Shows macOS's prompt the first time. Once refused, there's no second prompt: System Settings it is.
    func requestAccess() {
        refreshAccess()
        guard !hasAccess else { return }
        if hasAsked {
            CalendarService.openPrivacySettings("Privacy_ScreenCapture")
        } else {
            hasAsked = true
            UserDefaults.standard.set(true, forKey: "askedForScreenRecording")
            if !CGRequestScreenCaptureAccess() {
                // Nothing came of asking: the prompt is up, or the answer was no before.
            }
        }
        waitForAccess()
    }

    /// Access is granted in System Settings, which doesn't tell the app; look every couple of seconds for a while.
    private func waitForAccess() {
        accessPoll?.cancel()
        let deadline = Date.now.addingTimeInterval(600)
        accessPoll = EnergyCoordinator.shared.schedule(.accessibilityCheck) { [weak self] in
            guard let self else { return }
            self.refreshAccess()
            if self.hasAccess || Date.now >= deadline {
                self.accessPoll?.cancel()
                self.accessPoll = nil
            }
        }
    }

    // MARK: Freezing

    private enum CaptureError: Error {
        case noDisplays
    }

    /// Every display's pixels, without Dynotch's own windows, as they are right now.
    private func freeze() async throws -> [CaptureDisplay] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        let own = content.windows.filter { $0.owningApplication?.processID == pid }
        var displays: [CaptureDisplay] = []
        for screen in NSScreen.screens {
            guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { continue }
            let scale = screen.backingScaleFactor
            let configuration = SCStreamConfiguration()
            configuration.width = Int((screen.frame.width * scale).rounded())
            configuration.height = Int((screen.frame.height * scale).rounded())
            configuration.showsCursor = false
            configuration.captureResolution = .best
            let filter = SCContentFilter(display: display, excludingWindows: own)
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            displays.append(CaptureDisplay(id: screen.displayID, frame: screen.frame, scale: scale, image: image))
        }
        guard !displays.isEmpty else { throw CaptureError.noDisplays }
        return displays
    }

    // MARK: The editor

    private func show(_ displays: [CaptureDisplay]) {
        guard !displays.isEmpty else { return }
        NotchManager.shared.close()
        // The notch mustn't open or grow under the overlay while the pointer crosses it.
        NotchManager.shared.isPointerSuspended = true
        let editor = CaptureEditor(displays: displays, accent: AppSettings.shared.theme.accent)
        editor.onFinish = { [weak self] finish in self?.finish(finish) }
        editor.onCancel = { [weak self] in self?.tearDown() }
        self.editor = editor
        overlays = displays.enumerated().map { index, display in
            let window = CaptureOverlayWindow(display: display, editor: editor)
            if placesOverlaysOffScreen {
                window.setFrameOrigin(NSPoint(x: -20_000 - CGFloat(index) * 6_000, y: -70_000))
            }
            window.orderFrontRegardless()
            return window
        }
        // The keyboard goes to the display under the pointer; a click moves it.
        let pointer = NSEvent.mouseLocation
        (overlays.first { $0.display.frame.contains(pointer) } ?? overlays[0]).makeKeyAndOrderFront(nil)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.editor?.handleKey(event) ?? false }
            return handled ? nil : event
        }
        NSCursor.crosshair.set()
    }

    private func finish(_ finish: CaptureEditor.Finish) {
        guard let editor, let output = editor.render() else {
            tearDown()
            return
        }
        // Where the selection is on the desktop, from the overlay's frame: the display's, or off screen in a test.
        let place = overlays.first { $0.display.id == editor.activeDisplay }.flatMap { window in
            editor.selection.map { selection in
                CGRect(x: window.frame.minX + selection.minX, y: window.frame.maxY - selection.maxY,
                       width: selection.width, height: selection.height)
            }
        }
        tearDown()
        if AppSettings.shared.shutterSound { playShutter() }
        let size = "\(Int(output.pointSize.width)) × \(Int(output.pointSize.height))"
        switch finish {
        case .copy:
            copy(output)
            notice(symbol: "doc.on.clipboard.fill", text: "Copied", detail: "\(size) capture on the clipboard")
        case .save:
            if let url = ScreenshotFile.save(output.image, scale: output.scale, in: saveFolderOverride) {
                notice(symbol: "camera.viewfinder", text: "Saved", detail: url.lastPathComponent)
            } else {
                notice(symbol: "exclamationmark.triangle.fill", text: "Not saved", detail: "Couldn't write to \(ScreenshotFile.folder().lastPathComponent)", tint: .orange)
            }
        case .copyAndSave:
            copy(output)
            if let url = ScreenshotFile.save(output.image, scale: output.scale, in: saveFolderOverride) {
                notice(symbol: "doc.on.clipboard.fill", text: "Copied", detail: "And saved as \(url.lastPathComponent)")
            } else {
                notice(symbol: "doc.on.clipboard.fill", text: "Copied", detail: "But it couldn't be saved", tint: .orange)
            }
        case .addToTray:
            guard let url = ScreenshotFile.save(output.image, scale: output.scale, in: saveFolderOverride) else {
                notice(symbol: "exclamationmark.triangle.fill", text: "Not saved", detail: "Couldn't write to \(ScreenshotFile.folder().lastPathComponent)", tint: .orange)
                return
            }
            TrayStore.shared.add([url])
            NotchManager.shared.open(tab: .tray)
        case .pin:
            PinnedCaptureWindow.pin(output, near: place)
        }
    }

    private func copy(_ output: CaptureOutput) {
        pasteboard.clearContents()
        if let png = ScreenshotFile.pngData(output.image, scale: output.scale) { pasteboard.setData(png, forType: .png) }
        if let tiff = ScreenshotFile.tiffData(output.image) { pasteboard.setData(tiff, forType: .tiff) }
    }

    private func notice(symbol: String, text: String, detail: String, tint: Color = .white) {
        LiveActivityCenter.shared.post(LiveNotice(key: "capture", symbol: symbol, tint: tint, text: text, detail: detail), for: 3)
    }

    /// The Screenshot app's click, which lives with the system sounds Core Audio keeps rather than in a Sounds folder.
    private func playShutter() {
        if shutter == nil { shutter = NSSound(contentsOfFile: Self.shutterPath, byReference: true) }
        shutter?.stop()
        shutter?.play()
    }

    private func tearDown() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        overlays.forEach { window in
            window.orderOut(nil)
            window.close()
        }
        overlays = []
        editor = nil
        CaptureRenderer.forgetPatches()
        NotchManager.shared.isPointerSuspended = false
        NSCursor.arrow.set()
    }

    // MARK: Test image

    /// A made-up display for tests and snapshots: a sky, a window with some text, and a few shapes.
    static func syntheticDisplay(id: CGDirectDisplayID, frame: CGRect, scale: CGFloat) -> CaptureDisplay? {
        let width = Int((frame.width * scale).rounded()), height = Int((frame.height * scale).rounded())
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        let size = frame.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSGradient(colors: [NSColor(red: 0.36, green: 0.52, blue: 0.86, alpha: 1), NSColor(red: 0.86, green: 0.55, blue: 0.62, alpha: 1)])?
            .draw(in: NSRect(origin: .zero, size: size), angle: -30)
        // A menu bar along the top.
        NSColor.white.withAlphaComponent(0.55).setFill()
        NSRect(x: 0, y: size.height - 24, width: size.width, height: 24).fill()
        text("Finder    File    Edit    View    Go    Window    Help", at: NSPoint(x: 16, y: size.height - 18), size: 13, weight: .medium,
             color: NSColor.black.withAlphaComponent(0.75))
        // A document window with a title bar and a page of text.
        let window = NSRect(x: size.width * 0.12, y: size.height * 0.18, width: size.width * 0.5, height: size.height * 0.6)
        NSColor.black.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: window.offsetBy(dx: 0, dy: -6).insetBy(dx: -4, dy: -4), xRadius: 14, yRadius: 14).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: window, xRadius: 10, yRadius: 10).fill()
        NSColor(white: 0.93, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: window.minX, y: window.maxY - 38, width: window.width, height: 38), xRadius: 10, yRadius: 10).fill()
        for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: window.minX + 14 + CGFloat(index) * 20, y: window.maxY - 25, width: 12, height: 12)).fill()
        }
        text("Quarterly notes.md", at: NSPoint(x: window.midX - 60, y: window.maxY - 26), size: 13, weight: .semibold, color: .black)
        text("Dynotch capture test", at: NSPoint(x: window.minX + 32, y: window.maxY - 90), size: 28, weight: .bold, color: .black)
        let lines = ["The quick brown fox jumps over the lazy dog, then naps in the sun.",
                     "Pack my box with five dozen liquor jugs before the market closes.",
                     "Sphinx of black quartz, judge my vow: the capture tool is here.",
                     "Blur hides text like this; the arrow and the counters point things out."]
        for (index, line) in lines.enumerated() {
            text(line, at: NSPoint(x: window.minX + 32, y: window.maxY - 130 - CGFloat(index) * 30), size: 15, weight: .regular,
                 color: NSColor(white: 0.2, alpha: 1))
        }
        // Shapes to the right, for drawing over.
        for (index, color) in [NSColor.systemOrange, .systemTeal, .systemPurple].enumerated() {
            color.setFill()
            let side = size.width * 0.07
            NSBezierPath(ovalIn: NSRect(x: size.width * 0.7 + CGFloat(index) * side * 0.8, y: size.height * 0.62 - CGFloat(index) * side * 0.5,
                                        width: side, height: side)).fill()
        }
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: NSRect(x: size.width * 0.7, y: size.height * 0.22, width: size.width * 0.22, height: size.height * 0.26),
                     xRadius: 12, yRadius: 12).fill()
        text("Sidebar", at: NSPoint(x: size.width * 0.72, y: size.height * 0.42), size: 17, weight: .semibold, color: .black)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        return CaptureDisplay(id: id, frame: frame, scale: scale, image: image)
    }

    private static func text(_ string: String, at point: NSPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
            .draw(at: point)
    }
}
