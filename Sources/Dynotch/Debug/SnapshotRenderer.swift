import AppKit
import SwiftUI

/// `Dynotch --snapshot <folder>` renders the notch in each state with sample data,
/// so the UI can be reviewed without driving the real thing.
@MainActor
enum SnapshotRenderer {
    private struct Scene {
        let name: String
        let phase: NotchViewModel.Phase
        var activity: ClosedActivity = .idle
        var secondary: CompactActivity?
        var tab: NotchTab = .home
        var draggingFiles = false
        var hasTrack = true
    }

    static func render(into folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        PowerMonitor.shared.start()
        loadSamples(in: folder)

        let geometry = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                                     closedSize: CGSize(width: 185, height: 32), hasHardwareNotch: true)
        let volume = LiveNotice(key: "volume", symbol: "speaker.wave.2.fill", tint: .white, kind: .meter(0.62))
        let charging = LiveNotice(key: "power", symbol: "bolt.fill", tint: .green, text: "82%")
        let event = LiveNotice(key: "event", symbol: "calendar", tint: .orange, text: "in 5m", detail: "Design review")
        let scenes = [
            Scene(name: "01-closed-idle", phase: .closed),
            Scene(name: "02-closed-hover", phase: .hovering),
            Scene(name: "03-closed-music", phase: .closed, activity: .music),
            Scene(name: "04-closed-track-peek", phase: .closed, activity: .trackPeek),
            Scene(name: "05-closed-timer", phase: .closed, activity: .timer),
            Scene(name: "06-closed-volume", phase: .closed, activity: .notice(volume)),
            Scene(name: "07-closed-charging", phase: .closed, activity: .notice(charging)),
            Scene(name: "08-closed-event", phase: .closed, activity: .notice(event)),
            Scene(name: "10-open-nook", phase: .open, tab: .home),
            Scene(name: "11-open-nook-empty", phase: .open, tab: .home, hasTrack: false),
            Scene(name: "12-open-tray", phase: .open, tab: .tray),
            Scene(name: "13-open-tray-dropping", phase: .open, tab: .tray, draggingFiles: true),
            Scene(name: "14-open-focus", phase: .open, tab: .focus),
            Scene(name: "15-open-stats", phase: .open, tab: .stats),
            Scene(name: "20-closed-timer-and-music", phase: .closed, activity: .timer, secondary: .music),
            Scene(name: "21-closed-volume-and-timer", phase: .closed, activity: .notice(volume), secondary: .timer),
            Scene(name: "22-closed-track-peek-and-timer", phase: .closed, activity: .trackPeek, secondary: .timer),
            Scene(name: "23-closed-event-and-timer", phase: .closed, activity: .notice(event), secondary: .timer),
            Scene(name: "24-hover-timer-and-music", phase: .hovering, activity: .timer, secondary: .music),
        ]

        let settings = AppSettings.shared
        let size = CGSize(width: settings.openWidth + NotchMetrics.openTopRadius * 2 + 80, height: settings.openHeight + 40)
        for scene in scenes {
            if scene.hasTrack { loadTrack() } else { NowPlayingService.shared.loadSample(nil) }
            let viewModel = NotchViewModel(geometry: geometry)
            viewModel.stage(phase: scene.phase, activity: scene.activity, secondary: scene.secondary, tab: scene.tab,
                            draggingFiles: scene.draggingFiles)
            let content = ZStack(alignment: .top) {
                Desktop(notchWidth: geometry.closedSize.width, menuBarHeight: geometry.closedSize.height)
                NotchRootView(viewModel: viewModel)
            }
            .frame(width: size.width, height: size.height)
            .environment(\.isSnapshot, true)

            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: folder.appendingPathComponent(scene.name + ".png"))
        }
        print("Wrote \(scenes.count) snapshots to \(folder.path)")
        renderSettings(into: folder)
    }

    // MARK: Settings

    /// Renders every settings page, light and dark, in a real window parked off screen. A page
    /// that scrolls gets a second image scrolled to the end. ImageRenderer can't draw the
    /// AppKit-backed views a settings page is made of.
    private static func renderSettings(into folder: URL) {
        var count = 0
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for page in SettingsPage.allCases {
                let window = OffscreenWindow(contentRect: NSRect(origin: .zero, size: SettingsWindowController.contentSize),
                                             styleMask: SettingsWindowController.styleMask, backing: .buffered, defer: false)
                let navigation = SettingsNavigation()
                navigation.page = page
                SettingsWindowController.configure(window, navigation: navigation)
                window.appearance = NSAppearance(named: appearance)
                // A fresh spot for every window, so the window server never shows a stale one.
                window.setFrameOrigin(NSPoint(x: -20_000 - CGFloat(count) * 1_000, y: -20_000))
                window.orderFrontRegardless()
                // Let tasks finish and animations settle.
                RunLoop.main.run(until: .now + 1.2)
                let name = String(format: "settings-%d-%@-%@", page.number, page.rawValue, suffix)
                if save(window, to: folder.appendingPathComponent(name + ".png")) { count += 1 }
                if let scrollView = window.contentView.flatMap(overflowingScrollView), let document = scrollView.documentView {
                    let end = document.isFlipped ? document.frame.height - scrollView.contentView.bounds.height : 0
                    scrollView.contentView.scroll(to: NSPoint(x: 0, y: end))
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                    RunLoop.main.run(until: .now + 0.8)
                    if save(window, to: folder.appendingPathComponent(name + "-end.png")) { count += 1 }
                }
                window.orderOut(nil)
                window.close()
            }
        }
        print("Wrote \(count) settings snapshots to \(folder.path)")
    }

    /// Writes the window to a PNG, trying again if the window server hands back a blank frame.
    private static func save(_ window: NSWindow, to url: URL) -> Bool {
        for _ in 0..<4 {
            guard let image = capture(window) else { return false }
            let bitmap = NSBitmapImageRep(cgImage: image)
            if isBlank(bitmap) {
                RunLoop.main.run(until: .now + 0.5)
                continue
            }
            guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
            return (try? png.write(to: url)) != nil
        }
        return false
    }

    /// One color all over, sampled on a grid.
    private static func isBlank(_ bitmap: NSBitmapImageRep) -> Bool {
        let first = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)
        for row in 1..<8 {
            for column in 1..<8 {
                let color = bitmap.colorAt(x: bitmap.pixelsWide * column / 8, y: bitmap.pixelsHigh * row / 8)
                if color != first { return false }
            }
        }
        return true
    }

    /// The first scroll view in `view` whose content doesn't fit.
    private static func overflowingScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView, let document = scrollView.documentView,
           document.frame.height > scrollView.contentView.bounds.height + 1 {
            return scrollView
        }
        return view.subviews.lazy.compactMap(overflowingScrollView).first
    }

    /// The window as the window server draws it. `CGWindowListCreateImage` is gone from the SDK but
    /// still works at run time, and a process may capture its own windows without screen-recording access.
    private static func capture(_ window: NSWindow) -> CGImage? {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let createImage = unsafeBitCast(symbol, to: CreateImage.self)
        let includingWindow: UInt32 = 1 << 3, ignoreFraming: UInt32 = 1 << 0, bestResolution: UInt32 = 1 << 3
        return createImage(.null, includingWindow, UInt32(window.windowNumber), ignoreFraming | bestResolution)?
            .takeRetainedValue()
    }

    private static func loadTrack() {
        NowPlayingService.shared.loadSample(
            NowPlayingService.Track(title: "Midnight City", artist: "M83", album: "Hurry Up, We're Dreaming", duration: 243),
            artwork: sampleArtwork(), playing: true, elapsed: 81)
    }

    private static func loadSamples(in folder: URL) {
        let now = Date.now
        let calendar = Calendar.current
        func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }
        CalendarService.shared.loadSample(
            events: [
                .init(id: "1", title: "Design review", start: at(12), end: at(57), isAllDay: false, color: .orange,
                      meetingURL: URL(string: "https://meet.google.com/abc-defg-hij")),
                .init(id: "2", title: "Lunch with Sam", start: at(140), end: at(200), isAllDay: false, color: .green, meetingURL: nil),
                .init(id: "3", title: "Ship v1.0", start: calendar.date(byAdding: .day, value: 1, to: now)!,
                      end: calendar.date(byAdding: .day, value: 1, to: at(60))!, isAllDay: false, color: .purple, meetingURL: nil),
            ],
            reminders: [
                .init(id: "a", title: "Send the invoice", dueDate: at(90), color: .orange),
                .init(id: "b", title: "Book flights for March", dueDate: calendar.date(byAdding: .day, value: 1, to: now), color: .blue),
                .init(id: "c", title: "Water the plants", dueDate: nil, color: .green),
            ])
        PomodoroTimer.shared.loadSample(remaining: 18 * 60 + 24, running: true)
        SystemMonitor.shared.loadSample()
        DeviceBatteryMonitor.shared.loadSample([
            .init(id: "airpods", name: "AirPods Pro", kind: .earbuds, left: 80, right: 78, batteryCase: 27),
            .init(id: "keyboard", name: "Magic Keyboard", kind: .keyboard, main: 64),
        ])
        // Registered, not saved, so a snapshot run never touches real notes.
        UserDefaults.standard.register(defaults: ["notes.text": "Call the bank about the card\nIdeas: notch widgets for weather"])

        let files = ["Q3 Report.pdf", "Hero shot.png", "Brand assets.zip", "Keynote draft.key", "notes.txt"]
        let samples = folder.appendingPathComponent("tray-samples", isDirectory: true)
        try? FileManager.default.createDirectory(at: samples, withIntermediateDirectories: true)
        let urls = files.map { samples.appendingPathComponent($0) }
        for url in urls where !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        TrayStore.shared.loadSample(urls)
    }

    /// A stand-in album cover.
    private static func sampleArtwork() -> NSImage {
        NSImage(size: NSSize(width: 300, height: 300), flipped: false) { rect in
            NSGradient(colors: [NSColor(red: 0.98, green: 0.36, blue: 0.55, alpha: 1),
                                NSColor(red: 0.42, green: 0.25, blue: 0.95, alpha: 1)])?.draw(in: rect, angle: -45)
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: 95, y: 95, width: 110, height: 110)).fill()
            NSColor(red: 0.42, green: 0.25, blue: 0.95, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 135, y: 135, width: 30, height: 30)).fill()
            return true
        }
    }
}

/// A window AppKit leaves where it's put, even off screen.
private final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// A wallpaper and translucent menu bar behind the snapshot, so the notch reads in context.
private struct Desktop: View {
    let notchWidth: CGFloat
    let menuBarHeight: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.36, green: 0.52, blue: 0.86), Color(red: 0.86, green: 0.55, blue: 0.62)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 18) {
                Text("Finder").fontWeight(.bold)
                Text("File")
                Text("Edit")
                Text("View")
                Spacer()
                Text("Tue 27 Oct  9:41")
            }
            .font(.system(size: 13))
            .foregroundStyle(.black.opacity(0.75))
            .padding(.horizontal, 16)
            .frame(height: menuBarHeight)
            .background(Color.white.opacity(0.55))
        }
    }
}
