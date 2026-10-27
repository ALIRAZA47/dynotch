import AppKit
import SwiftUI

/// `Dynotch --snapshot <folder>` renders the notch in each state with sample data,
/// so the UI can be reviewed without driving the real thing.
@MainActor
enum SnapshotRenderer {
    /// The moment sample timers count from, so every snapshot shows the same times.
    private static let sampleTime = Date.now

    private struct Scene {
        let name: String
        let phase: NotchViewModel.Phase
        var activity: ClosedActivity = .idle
        var secondary: CompactActivity?
        var tab: NotchTab = .home
        var draggingFiles = false
        var hasTrack = true
        var micMuted = false
        var micInUse = false
        var cameraInUse = false
        var hasTimers = true
        var downloadKnowsSize = true
        var focus: FocusMode?
        /// A look other than the user's, for this scene only.
        var theme: NotchTheme?
        /// A display other than a MacBook's, for this scene only.
        var geometry: NotchGeometry?
        /// More sample state for this scene; `resetAudioSamples` undoes it before the next one.
        var setUp: (@MainActor () -> Void)?
        /// Sample state for this scene. Scenes after it keep it.
        var prepare: (@MainActor () -> Void)?
    }

    static func render(into folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        PowerMonitor.shared.start()
        loadSamples(in: folder)

        let geometry = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                                     closedSize: CGSize(width: 185, height: 32), hasHardwareNotch: true)
        // An external display: the virtual notch hangs from a 24-point menu bar, or rests as a line.
        let virtualNotch = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                                         closedSize: CGSize(width: 190, height: 24), hasHardwareNotch: false)
        let line = NotchGeometry(screenFrame: virtualNotch.screenFrame, closedSize: virtualNotch.closedSize,
                                 hasHardwareNotch: false, isLine: true)
        let volume = LiveNotice(key: "volume", symbol: "speaker.wave.2.fill", tint: .white, kind: .meter(0.62))
        let charging = LiveNotice(key: "power", symbol: "bolt.fill", tint: .green, text: "82%")
        let event = LiveNotice(key: "event", symbol: "calendar", tint: .orange, text: "in 5m", detail: "Design review")
        let message = NotificationPeek.sample()
        let privateMessage = NotificationPeek.sample(hideText: true)
        // What `osascript -e 'display notification …'` looks like: Script Editor has no symbol of its own.
        let otherAppMessage = NotificationPeek.notice(
            for: NotificationReader.Entry(bundleID: "com.apple.ScriptEditor2", title: "Dynotch test", subtitle: "",
                                          body: "Hello from display notification"),
            appName: "Script Editor", hideText: false)
        let muted = LiveNotice(key: "mic", symbol: "mic.slash.fill", tint: .red, text: "Muted")
        let tea = TimerStore.shared.countdowns[0], laundry = TimerStore.shared.countdowns[1]
        let roast = Countdown(id: UUID(), name: "Slow roast pork", duration: 4 * 3600,
                              endDate: TimerStore.shared.now.addingTimeInterval(2 * 3600 + 750))
        let timerDone = LiveNotice(key: "countdown", symbol: "bell.fill", tint: TimerStore.tint, text: "Done", detail: "Tea · 4 min")
        let lateMessage = LiveNotice(key: "notification", symbol: "message.fill", tint: .green, text: "Anna",
                                 detail: "Running ten minutes late, start the review without me")
        let longMessage = LiveNotice(key: "notification", symbol: "message.fill", tint: .green, text: "Anna",
                                     detail: "Are we still on for lunch tomorrow? I booked the place by the river for half past twelve")
        let downloaded = LiveNotice(key: "download", symbol: "arrow.down.circle.fill", tint: DownloadMonitor.tint,
                                    text: "Downloaded", detail: "Keynote Themes.zip")
        let doNotDisturb = FocusMode(id: "dnd", name: "Do Not Disturb", symbol: "moon.fill", tint: .indigo)
        let work = FocusMode(id: "work", name: "Work", symbol: "briefcase.fill", tint: .teal)
        let focusOn = LiveNotice(key: "focus", symbol: "moon.fill", tint: .indigo, text: "On", detail: "Do Not Disturb")
        let focusOff = LiveNotice(key: "focus", symbol: "briefcase.fill", tint: Color.white.opacity(0.6), text: "Off", detail: "Work")
        let scenes = [
            Scene(name: "01-closed-idle", phase: .closed),
            Scene(name: "02-closed-hover", phase: .hovering),
            Scene(name: "03-closed-music", phase: .closed, activity: .music),
            Scene(name: "04-closed-track-peek", phase: .closed, activity: .trackPeek),
            Scene(name: "05-closed-timer", phase: .closed, activity: .timer),
            Scene(name: "06-closed-volume", phase: .closed, activity: .notice(volume)),
            Scene(name: "07-closed-charging", phase: .closed, activity: .notice(charging)),
            Scene(name: "08-closed-event", phase: .closed, activity: .notice(event)),
            Scene(name: "09-closed-notification", phase: .closed, activity: .notice(message)),
            Scene(name: "09-closed-notification-private", phase: .closed, activity: .notice(privateMessage)),
            Scene(name: "09-closed-notification-other-app", phase: .closed, activity: .notice(otherAppMessage)),
            Scene(name: "10-open-nook", phase: .open, tab: .home),
            Scene(name: "11-open-nook-empty", phase: .open, tab: .home, hasTrack: false),
            Scene(name: "12-open-tray", phase: .open, tab: .tray),
            Scene(name: "13-open-tray-dropping", phase: .open, tab: .tray, draggingFiles: true),
            Scene(name: "14-open-focus", phase: .open, tab: .focus),
            Scene(name: "15-open-stats", phase: .open, tab: .stats),
            // Themes
            Scene(name: "16-open-nook-glass", phase: .open, tab: .home, theme: NotchTheme(material: .glass)),
            Scene(name: "17-open-focus-glass", phase: .open, tab: .focus, theme: NotchTheme(material: .glass)),
            Scene(name: "18-open-stats-pink-round", phase: .open, tab: .stats,
                  theme: NotchTheme(accent: .pink, topRadius: 18, bottomRadius: 40)),
            Scene(name: "19-open-tray-teal-square", phase: .open, tab: .tray,
                  theme: NotchTheme(accent: .teal, topRadius: 8, bottomRadius: 18),
                  setUp: { TrayStore.shared.select(TrayStore.shared.items[1]) }),
            Scene(name: "20-closed-timer-and-music", phase: .closed, activity: .timer, secondary: .music),
            Scene(name: "21-closed-volume-and-timer", phase: .closed, activity: .notice(volume), secondary: .timer),
            Scene(name: "22-closed-track-peek-and-timer", phase: .closed, activity: .trackPeek, secondary: .timer),
            Scene(name: "23-closed-event-and-timer", phase: .closed, activity: .notice(event), secondary: .timer),
            Scene(name: "24-hover-timer-and-music", phase: .hovering, activity: .timer, secondary: .music),
            // Displays without a camera notch: the virtual notch, and the line that grows into it
            Scene(name: "25-virtual-notch-idle", phase: .closed, geometry: virtualNotch),
            Scene(name: "26-virtual-notch-music", phase: .closed, activity: .music, geometry: virtualNotch),
            Scene(name: "27-line-idle", phase: .closed, geometry: line),
            Scene(name: "28-line-hover", phase: .hovering, geometry: line),
            Scene(name: "29-line-music", phase: .closed, activity: .music, geometry: line),
            Scene(name: "30-closed-muted", phase: .closed, secondary: .micMuted, micMuted: true),
            Scene(name: "31-closed-music-muted", phase: .closed, activity: .music, secondary: .micMuted, micMuted: true),
            Scene(name: "32-closed-mute-notice", phase: .closed, activity: .notice(muted), micMuted: true),
            Scene(name: "33-closed-on-air-camera", phase: .closed, cameraInUse: true),
            Scene(name: "34-closed-on-air-mic-muted", phase: .closed, activity: .music, secondary: .micMuted,
                  micMuted: true, micInUse: true),
            Scene(name: "35-hover-on-air-timer", phase: .hovering, activity: .timer, micInUse: true, cameraInUse: true),
            Scene(name: "36-open-on-air", phase: .open, tab: .home, cameraInUse: true),
            Scene(name: "40-closed-countdown", phase: .closed, activity: .countdown(tea)),
            Scene(name: "41-closed-countdown-and-pomodoro", phase: .closed, activity: .countdown(tea), secondary: .timer),
            Scene(name: "42-closed-two-countdowns", phase: .closed, activity: .countdown(tea), secondary: .countdown(laundry)),
            Scene(name: "43-closed-long-countdown", phase: .closed, activity: .countdown(roast), secondary: .stopwatch),
            Scene(name: "44-closed-stopwatch-and-music", phase: .closed, activity: .stopwatch, secondary: .music),
            Scene(name: "45-closed-timer-done", phase: .closed, activity: .notice(timerDone)),
            Scene(name: "46-open-focus-no-timers", phase: .open, tab: .focus, hasTimers: false),
            Scene(name: "50-closed-message", phase: .closed, activity: .notice(lateMessage)),
            Scene(name: "51-closed-long-message", phase: .closed, activity: .notice(longMessage)),
            Scene(name: "52-closed-message-and-timer", phase: .closed, activity: .notice(lateMessage), secondary: .timer),
            Scene(name: "60-closed-download", phase: .closed, activity: .download),
            Scene(name: "61-closed-download-size", phase: .closed, activity: .download, downloadKnowsSize: false),
            Scene(name: "62-closed-download-and-music", phase: .closed, activity: .download, secondary: .music),
            Scene(name: "63-closed-timer-and-download", phase: .closed, activity: .timer, secondary: .download),
            Scene(name: "64-closed-downloaded", phase: .closed, activity: .notice(downloaded)),
            Scene(name: "70-closed-focus", phase: .closed, secondary: .focus(doNotDisturb), focus: doNotDisturb),
            Scene(name: "71-closed-music-and-focus", phase: .closed, activity: .music, secondary: .focus(work), focus: work),
            Scene(name: "72-closed-focus-on", phase: .closed, activity: .notice(focusOn), focus: doNotDisturb),
            Scene(name: "73-closed-focus-off", phase: .closed, activity: .notice(focusOff)),
            Scene(name: "74-closed-muted-and-focus", phase: .closed, secondary: .micMuted, micMuted: true, focus: work),
            Scene(name: "80-open-nook-volume", phase: .open, tab: .home,
                  setUp: { VolumeMonitor.shared.loadSample(volume: 0.62, changing: true) }),
            Scene(name: "81-open-nook-outputs", phase: .open, tab: .home, setUp: { loadOutputs(pickerShown: true) }),
            Scene(name: "82-open-nook-empty-outputs", phase: .open, tab: .home, hasTrack: false,
                  setUp: { loadOutputs(pickerShown: true) }),
            Scene(name: "83-closed-music-live-levels", phase: .closed, activity: .music,
                  setUp: { AudioLevels.shared.loadSample([0.95, 0.45, 0.7, 0.25]) }),
            Scene(name: "84-open-nook-live-levels", phase: .open, tab: .home,
                  setUp: { AudioLevels.shared.loadSample([0.3, 0.9, 0.55, 0.8]) }),
            // Widgets and the Tray
            Scene(name: "90-closed-screenshot", phase: .closed, activity: .notice(LiveNotice(
                key: "screenshot", symbol: "camera.viewfinder", tint: .white, detail: "Screenshot added to the Tray"))),
            Scene(name: "91-open-stats-bluetooth", phase: .open, tab: .stats) {
                DeviceBatteryMonitor.shared.loadSample([], paired: samplePairedDevices,
                                                       connections: ["beats": .connecting, "speaker": .failed("Not in range")])
            },
            Scene(name: "92-open-tray-selected", phase: .open, tab: .tray) {
                TrayStore.shared.select(TrayStore.shared.items[1])
            },
            Scene(name: "93-open-nook-weather-notes", phase: .open, tab: .home) {
                (AppSettings.shared.homeWidgetA, AppSettings.shared.homeWidgetB) = (.weather, .notes)
                WeatherService.shared.loadSample(place: "Lisbon", conditions: .init(
                    temperature: 18.4, high: 21.2, low: 12.6, code: 2, isDay: true, isRaining: false,
                    rainStart: .now.addingTimeInterval(20 * 60), isHeavyRain: false))
            },
            Scene(name: "94-open-nook-weather-setup", phase: .open, tab: .home) {
                (AppSettings.shared.homeWidgetA, AppSettings.shared.homeWidgetB) = (.weather, .devices)
                WeatherService.shared.loadSample(place: "", conditions: nil)
            },
            Scene(name: "95-closed-rain", phase: .closed, activity: .notice(LiveNotice(
                key: "rain", symbol: "cloud.rain.fill", tint: .cyan, text: "in 15m", detail: "Rain starting soon"))),
            // The other widgets beside the player, busy cards and empty ones. These change the samples, so they go last.
            Scene(name: "96-open-nook-timer-toggles", phase: .open, tab: .home, prepare: {
                (AppSettings.shared.homeWidgetA, AppSettings.shared.homeWidgetB) = (.timer, .toggles)
            }),
            Scene(name: "97-open-focus-busy", phase: .open, tab: .focus, setUp: {
                TimerStore.shared.start("pizza 12m")
            }, prepare: loadBusySamples),
            Scene(name: "98-open-nook-shortcuts-calendar", phase: .open, tab: .home, prepare: {
                (AppSettings.shared.homeWidgetA, AppSettings.shared.homeWidgetB) = (.shortcuts, .calendar)
                AppSettings.shared.pinnedShortcuts = ["Morning routine", "Log a glass of water", "Focus playlist"]
            }),
            Scene(name: "99-open-focus-empty", phase: .open, tab: .focus, hasTimers: false, prepare: {
                CalendarService.shared.loadSample(events: [], reminders: [])
                NotesStore.shared.loadSample([""])
            }),
        ]

        let settings = AppSettings.shared
        let size = CGSize(width: settings.openWidth + NotchTheme.standard.topRadius * 2 + 80, height: settings.openHeight + 40)
        let savedWidgets = (settings.homeWidgetA, settings.homeWidgetB)
        let savedShortcuts = settings.pinnedShortcuts
        let savedTheme = settings.theme
        for scene in scenes {
            apply(scene.theme ?? savedTheme)
            scene.prepare?()
            if scene.hasTrack { loadTrack() } else { NowPlayingService.shared.loadSample(nil) }
            resetAudioSamples()
            MicMonitor.shared.loadSample(muted: scene.micMuted, micInUse: scene.micInUse, cameraInUse: scene.cameraInUse)
            if scene.hasTimers { TimerStore.shared.loadSample(at: sampleTime) } else { TimerStore.shared.clearSample() }
            DownloadMonitor.shared.loadSample(knowsSize: scene.downloadKnowsSize)
            FocusMonitor.shared.loadSample(scene.focus)
            scene.setUp?()
            let sceneGeometry = scene.geometry ?? geometry
            let viewModel = NotchViewModel(geometry: sceneGeometry)
            viewModel.stage(phase: scene.phase, activity: scene.activity, secondary: scene.secondary, tab: scene.tab,
                            draggingFiles: scene.draggingFiles)
            let content = ZStack(alignment: .top) {
                Desktop(notchWidth: sceneGeometry.closedSize.width, menuBarHeight: sceneGeometry.closedSize.height)
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
        (settings.homeWidgetA, settings.homeWidgetB) = savedWidgets
        if settings.pinnedShortcuts != savedShortcuts { settings.pinnedShortcuts = savedShortcuts }
        apply(savedTheme)
        print("Wrote \(scenes.count) snapshots to \(folder.path)")
        loadSampleProfiles()
        renderSettings(into: folder)
        renderThemes(into: folder)
        renderProfiles(into: folder)
        renderWelcome(into: folder)
        renderCapture(into: folder)
    }

    // MARK: Capture

    /// The capture editor over a made-up display: a bare selection, the toolbar with marks of every
    /// kind, a text mark being typed, and a pinned capture.
    private static func renderCapture(into folder: URL) {
        guard let display = CaptureController.syntheticDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1280, height: 800), scale: 2)
        else { return }
        var count = 0
        let editor = CaptureEditor(displays: [display], accent: AppSettings.shared.theme.accent)
        let selection = CGRect(x: 118, y: 150, width: 700, height: 430)
        editor.stage(selection: selection, on: display.id)
        let window = CaptureOverlayWindow(display: display, editor: editor)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -60_000))
        window.orderFrontRegardless()
        RunLoop.main.run(until: .now + 1.2)
        if save(window, to: folder.appendingPathComponent("capture-1-selection.png")) { count += 1 }

        // The blur first, so the arrow over it stays whole.
        let marks: [Annotation] = [
            Annotation(kind: .blur(CGRect(x: 180, y: 384, width: 400, height: 56)), color: .red, width: 4),
            Annotation(kind: .arrow(from: CGPoint(x: 560, y: 470), to: CGPoint(x: 395, y: 352)), color: .red, width: 4),
            Annotation(kind: .rectangle(CGRect(x: 180, y: 268, width: 420, height: 44)), color: .orange, width: 3),
            Annotation(kind: .marker(points: [CGPoint(x: 188, y: 366), CGPoint(x: 540, y: 366)]), color: .yellow, width: 4),
            Annotation(kind: .counter(center: CGPoint(x: 160, y: 290), number: 1), color: .blue, width: 4),
            Annotation(kind: .counter(center: CGPoint(x: 160, y: 366), number: 2), color: .blue, width: 4),
            Annotation(kind: .ellipse(CGRect(x: 690, y: 200, width: 110, height: 110)), color: .green, width: 5),
            Annotation(kind: .pencil(points: stride(from: 0, through: 24, by: 1).map {
                CGPoint(x: 620 + Double($0) * 7, y: 520 + sin(Double($0) / 2.2) * 18)
            }), color: .purple, width: 3),
            Annotation(kind: .text(origin: CGPoint(x: 600, y: 420), string: "Ship it"), color: .black, width: 8),
        ]
        editor.stage(selection: selection, on: display.id, annotations: marks)
        editor.tool = .arrow
        RunLoop.main.run(until: .now + 1.0)
        if save(window, to: folder.appendingPathComponent("capture-2-editor-dark.png")) { count += 1 }
        window.appearance = NSAppearance(named: .aqua)
        RunLoop.main.run(until: .now + 0.8)
        if save(window, to: folder.appendingPathComponent("capture-2-editor-light.png")) { count += 1 }
        window.appearance = NSAppearance(named: .darkAqua)

        // A text mark being typed, in the color and width picked. Typed through the window, as a
        // person would, so the field shows an insertion point rather than a selection.
        editor.tool = .text
        editor.color = .yellow
        editor.width = 6
        window.makeKey()
        editor.mouseDown(at: CGPoint(x: 640, y: 236), on: display.id)
        editor.mouseUp(at: CGPoint(x: 640, y: 236), on: display.id)
        RunLoop.main.run(until: .now + 0.5)
        CaptureSelfTest.type("Review this", into: window)
        RunLoop.main.run(until: .now + 1.0)
        if save(window, to: folder.appendingPathComponent("capture-3-text.png")) { count += 1 }
        editor.discardText()
        window.orderOut(nil)
        window.close()

        if let output = editor.render() {
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let pin = PinnedCaptureWindow(output: output, frame: CGRect(x: -21_000, y: -61_000, width: output.pointSize.width,
                                                                              height: output.pointSize.height))
                pin.appearance = NSAppearance(named: appearance)
                pin.orderFrontRegardless()
                RunLoop.main.run(until: .now + 1.0)
                if save(pin, to: folder.appendingPathComponent("capture-4-pinned-\(suffix).png")) { count += 1 }
                pin.orderOut(nil)
                pin.close()
            }
        }
        print("Wrote \(count) capture snapshots to \(folder.path)")
    }

    /// Puts a theme in the settings, where the notch reads it. Only writes what differs.
    private static func apply(_ theme: NotchTheme) {
        let settings = AppSettings.shared
        guard settings.theme != theme else { return }
        settings.notchMaterial = theme.material
        settings.notchAccent = theme.accentChoice
        settings.notchTopRadius = theme.topRadius
        settings.notchBottomRadius = theme.bottomRadius
    }

    // MARK: Welcome tour

    /// Each step of the welcome tour, light and dark, plus its end when it scrolls.
    private static func renderWelcome(into folder: URL) {
        var count = 0
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for step in WelcomeTour.Step.allCases {
                let window = OffscreenWindow(contentRect: NSRect(origin: .zero, size: WelcomeWindowController.contentSize),
                                             styleMask: WelcomeWindowController.styleMask, backing: .buffered, defer: false)
                let tour = WelcomeTour()
                tour.step = step
                WelcomeWindowController.configure(window, tour: tour, isSnapshot: true)
                window.appearance = NSAppearance(named: appearance)
                window.setFrameOrigin(NSPoint(x: -20_000 - CGFloat(count) * 1_000, y: -50_000))
                window.orderFrontRegardless()
                RunLoop.main.run(until: .now + 1.2)
                let name = "welcome-\(step.rawValue + 1)-\(step)-\(suffix)"
                if save(window, to: folder.appendingPathComponent(name + ".png")) { count += 1 }
                if let scrollView = window.contentView.flatMap(overflowingScrollView), let document = scrollView.documentView,
                   document.isFlipped {
                    scrollView.contentView.scroll(to: NSPoint(x: 0, y: document.frame.height - scrollView.contentView.bounds.height))
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                    RunLoop.main.run(until: .now + 0.8)
                    if save(window, to: folder.appendingPathComponent(name + "-end.png")) { count += 1 }
                }
                window.orderOut(nil)
                window.close()
            }
        }
        print("Wrote \(count) welcome tour snapshots to \(folder.path)")
    }

    // MARK: Profiles

    private static func loadSampleProfiles() {
        FocusMonitor.shared.loadSample(nil, all: [
            FocusMode(id: "dnd", name: "Do Not Disturb", symbol: "moon.fill", tint: .indigo),
            FocusMode(id: "work", name: "Work", symbol: "briefcase.fill", tint: .teal),
        ])
        let values = Dictionary(uniqueKeysWithValues: ProfileSetting.all.map { ($0.key, $0.read(AppSettings.shared)) })
        func profile(_ name: String, _ rule: Profile.Rule?) -> Profile {
            Profile(id: UUID(), name: name, rule: rule, values: values)
        }
        ProfileStore.shared.loadSample([
            profile("Work", .focus(id: "work", name: "Work")),
            profile("Home", nil),
            profile("Desk", .externalDisplay),
            profile("Presenting", .focus(id: nil, name: "Any Focus")),
        ], active: 0)
    }

    /// The General page scrolled to its Profiles section, as the menu bar's Profile Settings opens it:
    /// with sample profiles in dark mode, and before there are any in light mode.
    private static func renderProfiles(into folder: URL) {
        var count = 0
        for (index, appearance) in [NSAppearance.Name.darkAqua, .aqua].enumerated() {
            if appearance == .aqua { ProfileStore.shared.loadSample([], active: nil) }
            ProfileStore.shared.revealRequested = true
            let window = OffscreenWindow(contentRect: NSRect(origin: .zero, size: SettingsWindowController.contentSize),
                                         styleMask: SettingsWindowController.styleMask, backing: .buffered, defer: false)
            let navigation = SettingsNavigation()
            navigation.page = .general
            SettingsWindowController.configure(window, navigation: navigation)
            window.appearance = NSAppearance(named: appearance)
            window.setFrameOrigin(NSPoint(x: -20_000 - CGFloat(index) * 1_000, y: -40_000))
            window.orderFrontRegardless()
            RunLoop.main.run(until: .now + 1.5)
            let name = appearance == .aqua ? "settings-profiles-empty-light" : "settings-profiles-dark"
            if save(window, to: folder.appendingPathComponent(name + ".png")) { count += 1 }
            window.orderOut(nil)
            window.close()
        }
        loadSampleProfiles()
        print("Wrote \(count) profile snapshots to \(folder.path)")
    }

    // MARK: Settings

    /// Renders every settings page, light and dark, in a real window parked off screen. A page
    /// that scrolls gets a second image scrolled to the end, and one for each screenful in between
    /// ("-2", "-3"...). ImageRenderer can't draw the AppKit-backed views a settings page is made of.
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
                    let viewport = scrollView.contentView.bounds.height
                    let end = document.isFlipped ? document.frame.height - viewport : 0
                    var offset = viewport - 60
                    var part = 2
                    while document.isFlipped, offset < end - 60 {
                        scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
                        scrollView.reflectScrolledClipView(scrollView.contentView)
                        RunLoop.main.run(until: .now + 0.8)
                        if save(window, to: folder.appendingPathComponent("\(name)-\(part).png")) { count += 1 }
                        offset += viewport - 60
                        part += 1
                    }
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
        renderSpotlights(into: folder)
    }

    /// The Live Activities page with its preview held on each activity, as when pointing at its tile.
    private static func renderSpotlights(into folder: URL) {
        var count = 0
        for (index, kind) in LiveActivityKind.allCases.enumerated() {
            let window = OffscreenWindow(contentRect: NSRect(origin: .zero, size: SettingsWindowController.contentSize),
                                         styleMask: SettingsWindowController.styleMask, backing: .buffered, defer: false)
            let navigation = SettingsNavigation()
            navigation.page = .activities
            navigation.spotlight = kind
            SettingsWindowController.configure(window, navigation: navigation)
            window.appearance = NSAppearance(named: .darkAqua)
            window.setFrameOrigin(NSPoint(x: -20_000 - CGFloat(index) * 1_000, y: -30_000))
            window.orderFrontRegardless()
            RunLoop.main.run(until: .now + 1.2)
            if save(window, to: folder.appendingPathComponent("stage-\(kind.rawValue).png")) { count += 1 }
            window.orderOut(nil)
            window.close()
        }
        print("Wrote \(count) live activity previews to \(folder.path)")
    }

    /// The Appearance page with other themes, so its header's model notch shows them, glass included.
    private static func renderThemes(into folder: URL) {
        let savedTheme = AppSettings.shared.theme
        let looks: [(name: String, appearance: NSAppearance.Name, theme: NotchTheme)] = [
            ("glass-dark", .darkAqua, NotchTheme(material: .glass, accent: .pink, topRadius: 16, bottomRadius: 38)),
            ("glass-light", .aqua, NotchTheme(material: .glass, accent: .teal, topRadius: 8, bottomRadius: 20)),
            ("graphite-dark", .darkAqua, NotchTheme(accent: .graphite, topRadius: 20, bottomRadius: 24)),
        ]
        var count = 0
        for (index, look) in looks.enumerated() {
            apply(look.theme)
            let window = OffscreenWindow(contentRect: NSRect(origin: .zero, size: SettingsWindowController.contentSize),
                                         styleMask: SettingsWindowController.styleMask, backing: .buffered, defer: false)
            let navigation = SettingsNavigation()
            navigation.page = .appearance
            SettingsWindowController.configure(window, navigation: navigation)
            window.appearance = NSAppearance(named: look.appearance)
            window.setFrameOrigin(NSPoint(x: -20_000 - CGFloat(index) * 1_000, y: -40_000))
            window.orderFrontRegardless()
            RunLoop.main.run(until: .now + 1.2)
            if save(window, to: folder.appendingPathComponent("settings-2-appearance-\(look.name).png")) { count += 1 }
            window.orderOut(nil)
            window.close()
        }
        apply(savedTheme)
        print("Wrote \(count) theme previews to \(folder.path)")
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

    /// The volume, output and equalizer state every scene starts from.
    private static func resetAudioSamples() {
        VolumeMonitor.shared.loadSample(volume: 0.62, changing: false)
        loadOutputs(pickerShown: false)
        AudioLevels.shared.loadSample(nil)
    }

    private static func loadOutputs(pickerShown: Bool) {
        AudioOutputs.shared.loadSample(pickerShown: pickerShown)
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
        TimerStore.shared.loadSample(at: sampleTime)
        SystemMonitor.shared.loadSample()
        DeviceBatteryMonitor.shared.loadSample([
            .init(id: "airpods", name: "AirPods Pro", kind: .earbuds, left: 80, right: 78, batteryCase: 27),
            .init(id: "keyboard", name: "Magic Keyboard", kind: .keyboard, main: 64),
        ], paired: samplePairedDevices)
        // In memory only, so a snapshot run never touches real notes.
        NotesStore.shared.loadSample([
            "Weekend\n- [x] Book the campsite\n- [ ] Pack the tent\n- [ ] Call Sam about the car\nBring the good coffee",
            "Ideas\n- Notch widget for the weather",
        ])

        let files = ["Q3 Report.pdf", "Hero shot.png", "Brand assets.zip", "Keynote draft.key", "notes.txt"]
        let samples = folder.appendingPathComponent("tray-samples", isDirectory: true)
        try? FileManager.default.createDirectory(at: samples, withIntermediateDirectories: true)
        let urls = files.map { samples.appendingPathComponent($0) }
        for url in urls where !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        TrayStore.shared.loadSample(urls)
    }

    /// A day with more events and reminders than the cards have room for, and a long title or two.
    private static func loadBusySamples() {
        let now = Date.now
        func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }
        CalendarService.shared.loadSample(
            events: [
                .init(id: "1", title: "Design review", start: at(12), end: at(57), isAllDay: false, color: .orange,
                      meetingURL: URL(string: "https://meet.google.com/abc-defg-hij")),
                .init(id: "2", title: "Lunch with Sam", start: at(140), end: at(200), isAllDay: false, color: .green, meetingURL: nil),
                .init(id: "4", title: "Quarterly planning with the whole product team", start: at(215), end: at(275),
                      isAllDay: false, color: .blue, meetingURL: nil),
                .init(id: "5", title: "Yoga", start: at(300), end: at(360), isAllDay: false, color: .purple, meetingURL: nil),
            ],
            reminders: [
                .init(id: "a", title: "Send the invoice", dueDate: at(90), color: .orange),
                .init(id: "d", title: "Call the landlord about the leaking kitchen tap before the weekend", dueDate: at(-1500),
                      color: .red),
                .init(id: "b", title: "Book flights for March", dueDate: Calendar.current.date(byAdding: .day, value: 1, to: now),
                      color: .blue),
                .init(id: "c", title: "Water the plants", dueDate: nil, color: .green),
                .init(id: "e", title: "Renew the passport", dueDate: nil, color: .purple),
            ])
    }

    private static let samplePairedDevices: [DeviceBatteryMonitor.PairedDevice] = [
        .init(id: "beats", name: "Beats Studio Pro", kind: .headphones),
        .init(id: "speaker", name: "Kitchen Speaker", kind: .speaker),
        .init(id: "mouse", name: "Magic Mouse", kind: .mouse),
    ]

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
