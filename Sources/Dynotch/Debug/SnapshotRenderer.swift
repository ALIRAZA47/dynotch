import AppKit
import SwiftUI

/// `Dynotch --snapshot <folder>` renders the notch in each state with sample data,
/// so the UI can be reviewed without driving the real thing. Settings come from a scratch
/// domain with sample values (`useScratchDefaults`), so the images look the same on every Mac
/// and show nothing of the real settings.
@MainActor
enum SnapshotRenderer {
    /// The moment sample timers count from, so every snapshot shows the same times.
    private static let sampleTime = Date.now

    // MARK: Scratch defaults

    /// One a run, so two runs side by side don't trade settings. A path, not a plain name: cfprefsd
    /// writes out a plain name's changes up to ten seconds later, so its emptied domain would come
    /// back to ~/Library/Preferences after the run has gone. A path is written to its file at once.
    private static let scratchDomain = FileManager.default.temporaryDirectory
        .appendingPathComponent("app.dynotch.snapshot.\(ProcessInfo.processInfo.processIdentifier)").path

    /// Points every setting at a scratch domain holding sample values. Called before anything
    /// reads a setting; `discardScratchDefaults` clears it again when the run is done.
    static func useScratchDefaults() {
        guard let defaults = UserDefaults(suiteName: scratchDomain) else { return }
        defaults.removePersistentDomain(forName: scratchDomain)
        let samples: [String: Any] = [
            "hasLaunchedBefore": true,
            "weatherPlace": "Lisbon, Portugal", "weatherLatitude": 38.72, "weatherLongitude": -9.14,
            "pinnedShortcuts": ["Morning routine", "Log a glass of water", "Focus playlist"],
        ]
        for (key, value) in samples { defaults.set(value, forKey: key) }
        UserDefaults.dynotch = defaults
    }

    static func discardScratchDefaults() {
        UserDefaults.dynotch.removePersistentDomain(forName: scratchDomain)
        // An emptied domain still leaves its file behind, and every run has its own.
        UserDefaults.dynotch.synchronize()
        try? FileManager.default.removeItem(atPath: scratchDomain + ".plist")
    }

    private struct Scene {
        let name: String
        let phase: NotchViewModel.Phase
        var activity: ClosedActivity = .idle
        var secondary: CompactActivity?
        var tab: NotchTab = .home
        var draggingFiles = false
        /// One drop target has the files over it. See `snapshotDrop`.
        var targetsDrop = false
        var hasTrack = true
        var micMuted = false
        var micInUse = false
        var cameraInUse = false
        var hasTimers = true
        var downloadKnowsSize = true
        var focus: FocusMode?
        /// A look other than the user's, for this scene only.
        var theme: NotchTheme?
        /// The system's Reduce Transparency is on.
        var reducesTransparency = false
        /// A display other than a MacBook's, for this scene only.
        var geometry: NotchGeometry?
        /// The command field, with this typed into it.
        var command: String?
        /// The glance has turned to the recent list.
        var showingRecent = false
        /// The Focus tab's second card shows the notes.
        var focusShowsNotes = false
        /// The open notch at this size instead of the setting's, for this scene only.
        var openSize: CGSize?
        /// More sample state for this scene; `resetAudioSamples` undoes it before the next one.
        var setUp: (@MainActor () -> Void)?
        /// Sample state for this scene. Scenes after it keep it.
        var prepare: (@MainActor () -> Void)?
    }

    /// The images whose names start with one of these, or all of them when it's empty.
    private static var only: [String] = []

    private static func wanted(_ name: String) -> Bool {
        only.isEmpty || only.contains { name.hasPrefix($0) }
    }

    static func render(into folder: URL, only prefixes: [String] = []) {
        #if DEBUG
        NotchAccent.checkContrast()
        #endif
        only = prefixes
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
        // What `dynotch notify` shows: a script's own symbol and color, with the terminal badge.
        let scriptNotice = LiveNotice(key: "command", symbol: "checkmark.circle.fill", tint: .green, text: "Done",
                                      detail: "make test · 2m 14s", fromScript: true)
        let peek = NotificationPeek.notice(
            for: NotificationReader.Entry(bundleID: "com.apple.MobileSMS", title: "Anna", subtitle: "",
                                          body: "Running ten minutes late, start the review without me"),
            appName: "Messages", hideText: false)
        let code = NotificationPeek.notice(
            for: NotificationReader.Entry(bundleID: "com.apple.MobileSMS", title: "Acme Bank", subtitle: "",
                                          body: "Your verification code is 482 913"),
            appName: "Messages", hideText: false, findsCodes: true)
        let keynote = folder.appendingPathComponent("tray-samples/Keynote draft.key")
        let downloadedWithButtons = LiveNotice(key: "download", symbol: "arrow.down.circle.fill", tint: DownloadMonitor.tint,
                                               text: "Downloaded", detail: "Keynote draft.key",
                                               actions: [NoticeAction(title: "Open", kind: .openFile(keynote)),
                                                         NoticeAction(title: "Show", kind: .reveal(keynote))])
        let screenshot = LiveNotice(key: "screenshot", symbol: "camera.viewfinder", tint: .white,
                                    detail: "Screenshot added to the Tray",
                                    actions: [NoticeAction(title: "Show", kind: .openTab(.tray)),
                                              NoticeAction(title: "Open", kind: .openFile(keynote))])
        let update = LiveNotice(key: "update", symbol: "arrow.down.circle.fill", tint: NotchAccent.lavender.color,
                                text: "Update", detail: "Dynotch 1.5.0 is ready to install",
                                actions: [NoticeAction(title: "Install", kind: .installUpdate)])
        let meeting = LiveNotice(key: "event", symbol: "calendar", tint: .orange, text: "in 5m", detail: "Design review",
                                 actions: [NoticeAction(title: "Join", kind: .openURL(URL(string: "https://meet.google.com")!))])
        let scriptButton = LiveNotice(key: "command", symbol: "checkmark.circle.fill", tint: .green, text: "Deployed",
                                      detail: "api · 2m 14s", fromScript: true,
                                      actions: [NoticeAction(title: "Open", kind: .openURL(URL(string: "https://example.com")!))])
        let digest = NotificationPeek.digest(of: ["Slack": 8, "Mail": 3, "Messages": 1], during: "Work")
        let held = NoticeQueue.summary(of: [peek, downloaded, code, scriptNotice])
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
            Scene(name: "14-open-focus-notes", phase: .open, tab: .focus, focusShowsNotes: true),
            Scene(name: "15-open-control", phase: .open, tab: .stats),
            // Themes
            Scene(name: "16-open-nook-glass", phase: .open, tab: .home, theme: NotchTheme(material: .glass)),
            // Reduce Transparency keeps glass black: this one matches 10-open-nook.
            Scene(name: "16-open-nook-glass-reduced", phase: .open, tab: .home, theme: NotchTheme(material: .glass),
                  reducesTransparency: true),
            Scene(name: "17-open-focus-glass", phase: .open, tab: .focus, theme: NotchTheme(material: .glass)),
            Scene(name: "18-open-control-pink-round", phase: .open, tab: .stats,
                  theme: NotchTheme(accent: .pink, topRadius: 18, bottomRadius: 40)),
            Scene(name: "19-open-tray-teal-square", phase: .open, tab: .tray,
                  theme: NotchTheme(accent: .teal, topRadius: 8, bottomRadius: 18),
                  setUp: { TrayStore.shared.select(TrayStore.shared.items[1]) }),
        ] + accentScenes() + [
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
            Scene(name: "65-closed-script-notice", phase: .closed, activity: .notice(scriptNotice)),
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
            Scene(name: "91-open-control-bluetooth", phase: .open, tab: .stats, prepare: {
                DeviceBatteryMonitor.shared.loadSample([], paired: samplePairedDevices,
                                                       connections: ["beats": .connecting, "speaker": .failed("Not in range")])
            }),
            Scene(name: "92-open-tray-selected", phase: .open, tab: .tray, prepare: {
                TrayStore.shared.select(TrayStore.shared.items[1])
            }),
            // The Tray on glass, in the palest accent: its dimmest text, and a file name on the tint.
            Scene(name: "92-open-tray-selected-glass", phase: .open, tab: .tray,
                  theme: NotchTheme(material: .glass, accent: .yellow),
                  setUp: { TrayStore.shared.select(TrayStore.shared.items[1]) }),
            Scene(name: "93-open-nook-weather-notes", phase: .open, tab: .home, prepare: {
                (AppSettings.shared.homeWidgetA, AppSettings.shared.homeWidgetB) = (.weather, .notes)
                WeatherService.shared.loadSample(place: "Lisbon", conditions: .init(
                    temperature: 18.4, high: 21.2, low: 12.6, code: 2, isDay: true, isRaining: false,
                    rainStart: .now.addingTimeInterval(20 * 60), isHeavyRain: false))
            }),
            Scene(name: "94-open-nook-weather-setup", phase: .open, tab: .home, prepare: {
                (AppSettings.shared.homeWidgetA, AppSettings.shared.homeWidgetB) = (.weather, .devices)
                WeatherService.shared.loadSample(place: "", conditions: nil)
            }),
            Scene(name: "95-closed-rain", phase: .closed, activity: .notice(LiveNotice(
                key: "rain", symbol: "cloud.rain.fill", tint: .cyan, text: "in 15m", detail: "Rain starting soon"))),
            // The command field, empty and with something typed.
            Scene(name: "command-1-empty", phase: .open, command: ""),
            Scene(name: "command-2-timer", phase: .open, command: "tea 4m"),
            Scene(name: "command-3-sum", phase: .open, command: "18% of 240"),
            Scene(name: "command-4-reminder", phase: .open, command: "remind Call Sam 5pm"),
            Scene(name: "command-5-toggle", phase: .open, command: "dark"),
            Scene(name: "command-6-volume", phase: .open, command: "vol 30"),
            Scene(name: "command-7-awake", phase: .open, command: "awake 2h"),
            Scene(name: "command-8-output", phase: .open, command: "output"),
            Scene(name: "command-9-settings", phase: .open, command: "settings tray"),
            Scene(name: "command-10-join", phase: .open, command: "join"),
            Scene(name: "command-11-music", phase: .open, command: "ne"),
            // Glances: resting the pointer on the notch.
            Scene(name: "glance-1-music", phase: .glance, activity: .music),
            Scene(name: "glance-2-pomodoro", phase: .glance, activity: .timer),
            Scene(name: "glance-3-countdown", phase: .glance, activity: .countdown(tea)),
            Scene(name: "glance-4-event", phase: .glance, hasTrack: false),
            Scene(name: "glance-5-download", phase: .glance, activity: .download),
            Scene(name: "glance-6-message", phase: .glance, activity: .notice(lateMessage)),
            Scene(name: "glance-7-stopwatch", phase: .glance, activity: .stopwatch),
            // Nothing within the next quarter hour, so the glance looks at the day.
            Scene(name: "glance-8-today", phase: .glance, hasTrack: false, setUp: {
                let lunch = CalendarService.shared.events.filter { $0.title == "Lunch with Sam" }
                CalendarService.shared.loadSample(events: lunch, reminders: CalendarService.shared.reminders)
            }),
            // Notices with buttons, which only show here.
            Scene(name: "glance-9-message-open", phase: .glance, activity: .notice(peek)),
            Scene(name: "glance-10-code", phase: .glance, activity: .notice(code)),
            Scene(name: "glance-11-downloaded", phase: .glance, activity: .notice(downloadedWithButtons)),
            Scene(name: "glance-12-screenshot", phase: .glance, activity: .notice(screenshot)),
            Scene(name: "glance-13-update", phase: .glance, activity: .notice(update)),
            Scene(name: "glance-14-join", phase: .glance, activity: .notice(meeting)),
            Scene(name: "glance-15-script-button", phase: .glance, activity: .notice(scriptButton)),
            // The recent list, and the two ways in.
            Scene(name: "glance-16-recent", phase: .glance, showingRecent: true, setUp: { loadRecents() }),
            Scene(name: "glance-17-today-recent-awake", phase: .glance, hasTrack: false, setUp: {
                let lunch = CalendarService.shared.events.filter { $0.title == "Lunch with Sam" }
                CalendarService.shared.loadSample(events: lunch, reminders: CalendarService.shared.reminders)
                loadRecents()
                QuickToggles.shared.loadSample(awakeUntil: sampleTime.addingTimeInterval(102 * 60))
            }),
            Scene(name: "glance-18-music-recent", phase: .glance, activity: .music, setUp: { loadRecents() }),
            // While the Mac is quiet, and Keep Awake.
            Scene(name: "66-closed-held", phase: .closed, secondary: .held(3)),
            Scene(name: "67-closed-music-held", phase: .closed, activity: .music, secondary: .held(3)),
            Scene(name: "68-closed-on-air-held", phase: .closed, secondary: .held(12), micInUse: true),
            Scene(name: "69-closed-held-summary", phase: .closed, activity: .notice(held)),
            Scene(name: "75-closed-keep-awake", phase: .closed, secondary: .keepAwake),
            Scene(name: "76-closed-music-keep-awake", phase: .closed, activity: .music, secondary: .keepAwake),
            Scene(name: "77-closed-digest", phase: .closed, activity: .notice(digest)),
            Scene(name: "78-open-control-awake", phase: .open, tab: .stats, setUp: {
                QuickToggles.shared.loadSample(awakeUntil: sampleTime.addingTimeInterval(102 * 60))
            }),
            Scene(name: "79-open-tray-pinned", phase: .open, tab: .tray, setUp: { TrayStore.shared.loadSample(pinned: 1) }),
        ] + widgetScenes() + [
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
        ] + sizeScenes() + edgeScenes(virtualNotch: virtualNotch)

        let settings = AppSettings.shared
        let savedTheme = settings.theme
        let savedSize = (settings.openWidth, settings.openHeight)
        var written = 0
        for scene in scenes where wanted(scene.name) {
            apply(scene.theme ?? savedTheme)
            (settings.openWidth, settings.openHeight) = scene.openSize.map { ($0.width, $0.height) } ?? savedSize
            let size = CGSize(width: settings.openWidth + NotchTheme.standard.topRadius * 2 + 80, height: settings.openHeight + 40)
            scene.prepare?()
            AppSettings.shared.focusShowsNotes = scene.focusShowsNotes
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
                            draggingFiles: scene.draggingFiles, command: scene.command, showingRecent: scene.showingRecent)
            // The command field can make the notch taller than the setting.
            let height = max(size.height, viewModel.metrics.height + 40)
            let content = ZStack(alignment: .top) {
                Desktop(notchWidth: sceneGeometry.closedSize.width, menuBarHeight: sceneGeometry.closedSize.height)
                NotchRootView(viewModel: viewModel)
            }
            .frame(width: size.width, height: height)
            .environment(\.isSnapshot, true)
            .environment(\.snapshotDrop, scene.targetsDrop ? SnapshotDrop() : nil)
            .environment(\._accessibilityReduceTransparency, scene.reducesTransparency)

            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            // A drop target takes the drop as it appears, so it shows targeted from the second frame on.
            if scene.targetsDrop { _ = renderer.cgImage }
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { continue }
            if (try? png.write(to: folder.appendingPathComponent(scene.name + ".png"))) != nil { written += 1 }
        }
        apply(savedTheme)
        (settings.openWidth, settings.openHeight) = savedSize
        print("Wrote \(written) snapshots to \(folder.path)")
        loadSampleProfiles()
        renderSettings(into: folder)
        renderThemes(into: folder)
        renderProfiles(into: folder)
        renderWelcome(into: folder)
        renderCapture(into: folder)
        renderNotesLeftBehind(into: folder)
    }

    // MARK: Capture

    /// The capture editor over a made-up display: a bare selection, the toolbar with marks of every
    /// kind, a text mark being typed, and a pinned capture.
    private static func renderCapture(into folder: URL) {
        // One editor makes all four, each from the one before.
        guard wanted("capture") || only.contains(where: { $0.hasPrefix("capture") }),
              let display = CaptureController.syntheticDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1280, height: 800), scale: 2)
        else { return }
        var count = 0
        let editor = CaptureEditor(displays: [display], accent: AppSettings.shared.theme.accent)
        let selection = CGRect(x: 118, y: 150, width: 700, height: 430)
        editor.stage(selection: selection, on: display.id)
        // The chrome's glass as its black 0.85 stand-in, so the images don't depend on the glass.
        let window = CaptureOverlayWindow(display: display, editor: editor, isSnapshot: true)
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
                let name = "welcome-\(step.rawValue + 1)-\(step)-\(suffix)"
                guard wanted(name) else { continue }
                let window = OffscreenWindow(contentRect: NSRect(origin: .zero, size: WelcomeWindowController.contentSize),
                                             styleMask: WelcomeWindowController.styleMask, backing: .buffered, defer: false)
                let tour = WelcomeTour()
                tour.step = step
                WelcomeWindowController.configure(window, tour: tour, isSnapshot: true)
                window.appearance = NSAppearance(named: appearance)
                window.setFrameOrigin(NSPoint(x: -20_000 - CGFloat(count) * 1_000, y: -50_000))
                window.orderFrontRegardless()
                RunLoop.main.run(until: .now + 1.2)
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
            let name = appearance == .aqua ? "settings-profiles-empty-light" : "settings-profiles-dark"
            guard wanted(name) else { continue }
            if appearance == .aqua { ProfileStore.shared.loadSample([], active: nil) }
            ProfileStore.shared.revealRequested = true
            let window = OffscreenWindow(contentRect: NSRect(origin: .zero, size: SettingsWindowController.contentSize),
                                         styleMask: SettingsWindowController.styleMask, backing: .buffered, defer: false)
            let navigation = SettingsNavigation()
            navigation.page = .general
            SettingsWindowController.configure(window, navigation: navigation, isSnapshot: true)
            window.appearance = NSAppearance(named: appearance)
            window.setFrameOrigin(NSPoint(x: -20_000 - CGFloat(index) * 1_000, y: -40_000))
            window.orderFrontRegardless()
            RunLoop.main.run(until: .now + 1.5)
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
                let name = String(format: "settings-%d-%@-%@", page.number, page.rawValue, suffix)
                guard wanted(name) else { continue }
                let window = OffscreenWindow(contentRect: NSRect(origin: .zero, size: SettingsWindowController.contentSize),
                                             styleMask: SettingsWindowController.styleMask, backing: .buffered, defer: false)
                let navigation = SettingsNavigation()
                navigation.page = page
                SettingsWindowController.configure(window, navigation: navigation, isSnapshot: true)
                window.appearance = NSAppearance(named: appearance)
                // A fresh spot for every window, so the window server never shows a stale one.
                window.setFrameOrigin(NSPoint(x: -20_000 - CGFloat(count) * 1_000, y: -20_000))
                window.orderFrontRegardless()
                // Let tasks finish and animations settle.
                RunLoop.main.run(until: .now + 1.2)
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
        for (index, kind) in LiveActivityKind.allCases.enumerated() where wanted("stage-\(kind.rawValue)") {
            let window = OffscreenWindow(contentRect: NSRect(origin: .zero, size: SettingsWindowController.contentSize),
                                         styleMask: SettingsWindowController.styleMask, backing: .buffered, defer: false)
            let navigation = SettingsNavigation()
            navigation.page = .activities
            navigation.spotlight = kind
            SettingsWindowController.configure(window, navigation: navigation, isSnapshot: true)
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
        let looks: [(name: String, appearance: NSAppearance.Name, theme: NotchTheme, reducesTransparency: Bool)] = [
            ("glass-dark", .darkAqua, NotchTheme(material: .glass, accent: .pink, topRadius: 16, bottomRadius: 38), false),
            ("glass-light", .aqua, NotchTheme(material: .glass, accent: .teal, topRadius: 8, bottomRadius: 20), false),
            ("graphite-dark", .darkAqua, NotchTheme(accent: .graphite, topRadius: 20, bottomRadius: 24), false),
            ("glass-reduced-dark", .darkAqua, NotchTheme(material: .glass, accent: .pink, topRadius: 16, bottomRadius: 38), true),
        ]
        var count = 0
        for (index, look) in looks.enumerated() where wanted("settings-2-appearance-\(look.name)") {
            apply(look.theme)
            let window = OffscreenWindow(contentRect: NSRect(origin: .zero, size: SettingsWindowController.contentSize),
                                         styleMask: SettingsWindowController.styleMask, backing: .buffered, defer: false)
            let navigation = SettingsNavigation()
            navigation.page = .appearance
            SettingsWindowController.configure(window, navigation: navigation, isSnapshot: true)
            if look.reducesTransparency {
                let hosting = NSHostingController(rootView: SettingsView(navigation: navigation).environment(\.isSnapshot, true)
                    .environment(\._accessibilityReduceTransparency, true))
                hosting.sizingOptions = []
                window.contentViewController = hosting
                window.setContentSize(SettingsWindowController.contentSize)
            }
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

    /// The Notes card just after leaving a folder that kept its notes, in iCloud Drive and elsewhere,
    /// with the folder in use still empty. Last, as it empties the sample notes.
    private static func renderNotesLeftBehind(into folder: URL) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let samples: [(name: String, left: NotesStore.LeftBehind, appearance: NSAppearance.Name)] = [
            ("icloud-dark", .init(folder: home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Dynotch Notes"),
                                  count: 3), .darkAqua),
            ("icloud-light", .init(folder: home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Dynotch Notes"),
                                   count: 3), .aqua),
            ("folder-dark", .init(folder: home.appendingPathComponent("Documents/Obsidian Vault"), count: 1), .darkAqua),
        ]
        var count = 0
        for (index, sample) in samples.enumerated() where wanted("settings-4-nook-notes-left-\(sample.name)") {
            NotesStore.shared.loadSample([])
            NotesStore.shared.loadSample(leftBehind: sample.left)
            let window = OffscreenWindow(contentRect: NSRect(origin: .zero, size: SettingsWindowController.contentSize),
                                         styleMask: SettingsWindowController.styleMask, backing: .buffered, defer: false)
            let navigation = SettingsNavigation()
            navigation.page = .nook
            SettingsWindowController.configure(window, navigation: navigation, isSnapshot: true)
            window.appearance = NSAppearance(named: sample.appearance)
            window.setFrameOrigin(NSPoint(x: -20_000 - CGFloat(index) * 1_000, y: -60_000))
            window.orderFrontRegardless()
            RunLoop.main.run(until: .now + 1.2)
            if let scrollView = window.contentView.flatMap(overflowingScrollView) {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: 470))
                scrollView.reflectScrolledClipView(scrollView.contentView)
                RunLoop.main.run(until: .now + 0.8)
            }
            if save(window, to: folder.appendingPathComponent("settings-4-nook-notes-left-\(sample.name).png")) { count += 1 }
            window.orderOut(nil)
            window.close()
        }
        NotesStore.shared.loadSample(leftBehind: nil)
        print("Wrote \(count) notes folder snapshots to \(folder.path)")
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

    /// The volume, output and equalizer state every scene starts from, with nothing recent and
    /// Keep Awake off.
    private static func resetAudioSamples() {
        VolumeMonitor.shared.loadSample(volume: 0.62, changing: false)
        loadOutputs(pickerShown: false)
        AudioLevels.shared.loadSample(nil)
        LiveActivityCenter.shared.loadSample(recents: [], unseen: 0)
        QuickToggles.shared.loadSample(awakeUntil: nil)
        TrayStore.shared.loadSample(pinned: nil)
    }

    private static func loadRecents() {
        func recent(_ symbol: String, _ tint: Color, _ title: String, detail: String? = nil, minutes: Double, count: Int = 1,
                    actions: [NoticeAction] = []) -> RecentNotice {
            RecentNotice(id: UUID(), symbol: symbol, tint: tint, title: title, detail: detail,
                         date: sampleTime.addingTimeInterval(-minutes * 60), actions: actions, count: count)
        }
        LiveActivityCenter.shared.loadSample(recents: [
            recent("number.square.fill", Color(red: 0.93, green: 0.42, blue: 0.69), "Slack", minutes: 2, count: 3,
                   actions: [NoticeAction(title: "Open", kind: .openApp(bundleID: "com.tinyspeck.slackmacgap"))]),
            recent("arrow.down.circle.fill", DownloadMonitor.tint, "Downloaded", detail: "Keynote draft.key", minutes: 9),
            recent("bell.fill", TimerStore.tint, "Done", detail: "Tea · 4 min", minutes: 24),
            recent("message.fill", .green, "Messages", minutes: 75,
                   actions: [NoticeAction(title: "Open", kind: .openApp(bundleID: "com.apple.MobileSMS"))]),
        ], unseen: 4)
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

    /// Ink on each accent: the Control tab, its jewel and the Mute mic tile, which is on in every
    /// probe (the Dark tile follows the Mac's own appearance); on glass for the lightest and the
    /// greyest accent; and a drop zone with files over it.
    private static func accentScenes() -> [Scene] {
        NotchAccent.allCases.map { accent in
            Scene(name: "accent-\(accent.rawValue)-control", phase: .open, tab: .stats, micMuted: true,
                  theme: NotchTheme(accent: accent))
        } + [
            Scene(name: "accent-yellow-control-glass", phase: .open, tab: .stats, micMuted: true,
                  theme: NotchTheme(material: .glass, accent: .yellow)),
            Scene(name: "accent-graphite-control-glass", phase: .open, tab: .stats, micMuted: true,
                  theme: NotchTheme(material: .glass, accent: .graphite)),
            Scene(name: "accent-yellow-tray-dropping", phase: .open, tab: .tray, draggingFiles: true, targetsDrop: true,
                  theme: NotchTheme(accent: .yellow)),
        ]
    }

    /// The widgets no other scene brings to the top of the Nook's stack, each first in it beside one
    /// that never asks for the room, on black and on glass. They leave the widgets set, so they come
    /// just before 96, which sets its own.
    private static func widgetScenes() -> [Scene] {
        let stacks: [(name: String, first: HomeWidget, second: HomeWidget)] = [
            ("notes", .notes, .mirror), ("shortcuts", .shortcuts, .mirror),
            ("mirror", .mirror, .notes), ("toggles", .toggles, .mirror),
        ]
        return stacks.flatMap { stack in
            [nil, NotchTheme(material: .glass)].map { theme in
                Scene(name: "widget-\(stack.name)" + (theme == nil ? "" : "-glass"), phase: .open, tab: .home, theme: theme,
                      setUp: { (AppSettings.shared.homeWidgetA, AppSettings.shared.homeWidgetB) = (stack.first, stack.second) })
            }
        }
    }

    /// Each tab at the smallest and the largest open size the settings allow, with more in every
    /// list than fits, so content that runs over or leaves a gap shows.
    private static func sizeScenes() -> [Scene] {
        let sizes = [("small", CGSize(width: 600, height: 196)), ("large", CGSize(width: 840, height: 260))]
        return sizes.flatMap { label, size in
            [
                Scene(name: "size-\(label)-1-nook", phase: .open, tab: .home, openSize: size, prepare: loadCrowdedSamples),
                Scene(name: "size-\(label)-2-nook-batteries", phase: .open, tab: .home, openSize: size, prepare: {
                    (AppSettings.shared.homeWidgetA, AppSettings.shared.homeWidgetB) = (.devices, .calendar)
                }),
                Scene(name: "size-\(label)-3-tray", phase: .open, tab: .tray, openSize: size),
                Scene(name: "size-\(label)-4-tray-dropping", phase: .open, tab: .tray, draggingFiles: true, openSize: size),
                Scene(name: "size-\(label)-5-focus", phase: .open, tab: .focus, openSize: size),
                Scene(name: "size-\(label)-6-focus-notes", phase: .open, tab: .focus, focusShowsNotes: true, openSize: size),
                Scene(name: "size-\(label)-7-control", phase: .open, tab: .stats, openSize: size),
                Scene(name: "size-\(label)-8-nook-empty", phase: .open, tab: .home, hasTrack: false, openSize: size),
            ]
        } + sizes.map { label, size in
            // Last, as it empties the tray for good.
            Scene(name: "size-\(label)-9-tray-empty", phase: .open, tab: .tray, openSize: size, prepare: {
                TrayStore.shared.loadSample([])
            })
        }
    }

    /// States the samples never reach: Bluetooth not allowed, a session of hours, a long track, a
    /// cover in a deep color or none at all, the Sound row's mute, the open notch on a display
    /// without one. Last, as they leave the samples changed.
    private static func edgeScenes(virtualNotch: NotchGeometry) -> [Scene] {
        let short = CGSize(width: 680, height: 218), small = CGSize(width: 600, height: 196)
        let glass = NotchTheme(material: .glass)
        let noBluetooth: @MainActor () -> Void = { DeviceBatteryMonitor.shared.loadSample([], isAuthorized: false) }
        let mute: @MainActor () -> Void = { VolumeMonitor.shared.loadSample(volume: 0.62, changing: false, canMute: true) }
        let hours: @MainActor () -> Void = { PomodoroTimer.shared.loadSample(remaining: 2 * 3600 - 1, running: true) }
        let resting: @MainActor () -> Void = { PomodoroTimer.shared.loadSample(remaining: 25 * 60, running: false) }
        let longRate: @MainActor () -> Void = { SystemMonitor.shared.loadSample(cpu: 1, download: 120_400_000) }
        let sampleTrack = NowPlayingService.Track(title: "Midnight City", artist: "M83", album: "Hurry Up, We're Dreaming",
                                                  duration: 243)
        func cover(_ color: NSColor) -> @MainActor () -> Void {
            { NowPlayingService.shared.loadSample(sampleTrack, artwork: solidCover(color), playing: true, elapsed: 81) }
        }
        let noCover: @MainActor () -> Void = { NowPlayingService.shared.loadSample(sampleTrack, playing: true, elapsed: 81) }
        let longTrack: @MainActor () -> Void = {
            NowPlayingService.shared.loadSample(
                NowPlayingService.Track(title: "Midnight City", artist: "M83", album: "Hurry Up, We're Dreaming", duration: 7265),
                artwork: sampleArtwork(), playing: true, elapsed: 3700)
        }
        let detailOnly = LiveNotice(key: "screenshot", symbol: "camera.viewfinder", tint: .white,
                                    detail: "Screenshot added to the Tray")
        return [
            Scene(name: "edge-mute-control", phase: .open, tab: .stats, setUp: mute),
            Scene(name: "edge-mute-control-small", phase: .open, tab: .stats, openSize: small, setUp: mute),
            Scene(name: "edge-control-short", phase: .open, tab: .stats, openSize: CGSize(width: 680, height: 220)),
            Scene(name: "edge-focus-hours", phase: .open, tab: .focus, prepare: hours),
            Scene(name: "edge-focus-hours-short", phase: .open, tab: .focus, openSize: short, prepare: hours),
            Scene(name: "edge-focus-resting-short", phase: .open, tab: .focus, openSize: short, prepare: resting),
            Scene(name: "edge-focus-overdue-glass", phase: .open, tab: .focus, theme: glass, setUp: {
                TimerStore.shared.start("pizza 12m")
            }, prepare: {
                PomodoroTimer.shared.loadSample(remaining: 18 * 60 + 24, running: true)
                loadBusySamples()
            }),
            Scene(name: "edge-long-track", phase: .open, tab: .home, setUp: longTrack),
            Scene(name: "edge-long-track-small", phase: .open, tab: .home, openSize: small, setUp: longTrack),
            Scene(name: "edge-cover-navy", phase: .open, tab: .home, setUp: cover(NSColor(srgbRed: 0, green: 0.06, blue: 0.75, alpha: 1))),
            Scene(name: "edge-cover-violet", phase: .open, tab: .home, setUp: cover(NSColor(srgbRed: 0.3, green: 0, blue: 0.7, alpha: 1))),
            Scene(name: "edge-cover-navy-glass", phase: .open, tab: .home, theme: glass,
                  setUp: cover(NSColor(srgbRed: 0, green: 0.06, blue: 0.75, alpha: 1))),
            Scene(name: "edge-no-cover-glance", phase: .glance, activity: .music, setUp: noCover),
            Scene(name: "edge-no-cover-nook", phase: .open, tab: .home, setUp: noCover),
            Scene(name: "edge-notice-detail-only", phase: .glance, activity: .notice(detailOnly)),
            Scene(name: "edge-four-shortcuts-small", phase: .open, tab: .home, openSize: small, prepare: {
                (AppSettings.shared.homeWidgetA, AppSettings.shared.homeWidgetB) = (.shortcuts, .mirror)
                AppSettings.shared.pinnedShortcuts = ["Morning routine", "Log a glass of water", "Focus playlist", "Start the day"]
            }),
            Scene(name: "edge-command-glass", phase: .open, theme: glass, command: ""),
            Scene(name: "edge-virtual-notch-control", phase: .open, tab: .stats, geometry: virtualNotch),
            Scene(name: "edge-virtual-notch-command", phase: .open, geometry: virtualNotch, command: ""),
            // These change the Control tab for every scene after them.
            Scene(name: "edge-long-rate-small", phase: .open, tab: .stats, openSize: small, prepare: longRate),
            Scene(name: "edge-no-bluetooth-control", phase: .open, tab: .stats, prepare: {
                SystemMonitor.shared.loadSample()
                noBluetooth()
            }),
            Scene(name: "edge-no-bluetooth-control-small", phase: .open, tab: .stats, openSize: small),
        ]
    }

    /// A cover of one color.
    private static func solidCover(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            color.setFill()
            rect.fill()
            return true
        }
    }

    /// A busy day, a long note and more Bluetooth devices than a card has room for.
    private static func loadCrowdedSamples() {
        loadBusySamples()
        (AppSettings.shared.homeWidgetA, AppSettings.shared.homeWidgetB) = (.calendar, .devices)
        NotesStore.shared.loadSample([
            "Weekend\n- [x] Book the campsite\n- [ ] Pack the tent\n- [ ] Call Sam about the car\n- [ ] Buy firewood\n"
                + "- [ ] Charge the lamps\n- [ ] Check the weather\nBring the good coffee",
            "Ideas\n- Notch widget for the weather",
        ])
        DeviceBatteryMonitor.shared.loadSample([
            .init(id: "airpods", name: "AirPods Pro", kind: .earbuds, left: 80, right: 78, batteryCase: 27),
            .init(id: "keyboard", name: "Magic Keyboard", kind: .keyboard, main: 64),
            .init(id: "trackpad", name: "Magic Trackpad", kind: .trackpad, main: 41),
            .init(id: "mouse", name: "MX Master 3S", kind: .mouse, main: 18),
            .init(id: "controller", name: "DualSense Wireless Controller", kind: .gamepad, main: 92),
            .init(id: "beats", name: "Beats Studio Pro", kind: .headphones, main: 55),
        ], paired: samplePairedDevices)
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
