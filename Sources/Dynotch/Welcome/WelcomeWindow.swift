import AppKit
import SwiftUI

/// The tour a new user sees on first launch, in place of Settings: what the notch does, what's
/// new, the permissions worth giving, and where things are. Settings → About and the menu bar
/// menu bring it back.
@MainActor
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    static let shared = WelcomeWindowController()
    static let contentSize = NSSize(width: 760, height: 720)
    static let styleMask: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView]

    private let tour = WelcomeTour()

    private init() {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.contentSize), styleMask: Self.styleMask,
                              backing: .buffered, defer: false)
        super.init(window: window)
        Self.configure(window, tour: tour)
        tour.finish = { [weak window] in window?.performClose(nil) }
        window.center()
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    /// Fills a window with the tour. The snapshot renderer uses this for its own windows.
    static func configure(_ window: NSWindow, tour: WelcomeTour, isSnapshot: Bool = false) {
        window.title = "Welcome to Dynotch"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        let hosting = NSHostingController(rootView: WelcomeView(tour: tour).environment(\.isSnapshot, isSnapshot))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(contentSize)
    }

    /// Shows the tour, from the start unless it's already open.
    func show() {
        if window?.isVisible != true { tour.step = .notch }
        // In the Dock and the app switcher while the window is open, like Settings.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        DockPresence.windowWillClose(window)
    }
}

/// Dynotch shows in the Dock while Settings or the welcome tour is open, and leaves it when the
/// last of them closes.
@MainActor
enum DockPresence {
    static func windowWillClose(_ closing: NSWindow?) {
        let othersOpen = NSApp.windows.contains { window in
            window !== closing && window.isVisible && window.styleMask.contains(.titled) && !(window is NSPanel)
        }
        if !othersOpen { NSApp.setActivationPolicy(.accessory) }
    }
}

/// Where the tour is.
@MainActor
final class WelcomeTour: ObservableObject {
    enum Step: Int, CaseIterable, Identifiable {
        case notch, highlights, permissions, done

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .notch: "Meet your notch"
            case .highlights: "What's new"
            case .permissions: "Permissions"
            case .done: "You're all set"
            }
        }

        var subtitle: String {
            switch self {
            case .notch: "Music, files, your calendar and more, one hover away."
            case .highlights: "A few of the things this version brings to the notch."
            case .permissions: "Allow what you'd like now. The rest is asked for when a feature first needs it."
            case .done: "Dynotch lives in the notch and in the menu bar."
            }
        }
    }

    @Published var step = Step.notch
    var finish: () -> Void = {}

    func next() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return finish() }
        withAnimation(stepAnimation) { step = next }
    }

    func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        withAnimation(stepAnimation) { step = previous }
    }

    /// A spring, or an ease with Reduce Motion. Nothing here has an environment to ask.
    private var stepAnimation: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.86)
    }
}

/// A header with the model notch acting out the step, the step underneath, and a footer to move on.
/// Everything in it draws in the user's accent, as Settings does.
struct WelcomeView: View {
    @ObservedObject var tour: WelcomeTour
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            WelcomeStage(tour: tour)
            ScrollView {
                content
                    .padding(.horizontal, 26)
                    .padding(.top, 22)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .id(tour.step)
            .transition(.opacity)
            WelcomeFooter(tour: tour)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.window)
        .ignoresSafeArea()
        .windowAccent(WindowAccent(choice: settings.notchAccent))
    }

    @ViewBuilder
    private var content: some View {
        switch tour.step {
        case .notch: NotchStep()
        case .highlights: HighlightsStep()
        case .permissions: PermissionsStep()
        case .done: DoneStep(tour: tour)
        }
    }
}

// MARK: Stage

private struct WelcomeStage: View {
    @ObservedObject var tour: WelcomeTour
    @ObservedObject private var permissions = PermissionStatus.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private static let cycle: TimeInterval = 2.2

    var body: some View {
        let step = tour.step
        let ink = StageInk(colorScheme: colorScheme, contrast: contrast)
        ZStack(alignment: .bottom) {
            StageSky()
            TimelineView(.periodic(from: .now, by: cycles ? Self.cycle : 3600)) { context in
                let tick = isSnapshot ? 2 : Int(context.date.timeIntervalSinceReferenceDate / Self.cycle)
                let scene = scene(tick: tick)
                VStack(spacing: 13) {
                    ModelNotch(pose: scene.pose)
                    CaptionText(scene.caption, isNumeric: false)
                }
                .animation(reduceMotion ? .easeOut(duration: 0.2) : .notchOpen, value: scene.pose)
            }
            .animation(reduceMotion ? .easeOut(duration: 0.2) : .notchOpen, value: step)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .accessibilityHidden(true)
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(step.title)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(ink.primary)
                        .accessibilityAddTraits(.isHeader)
                    Text(step.subtitle)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(ink.secondary)
                }
                .id(step)
                .transition(.opacity)
                Spacer(minLength: 0)
                if step != .done {
                    CapsuleButton(title: "Skip Tour", kind: .glass) { tour.finish() }
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 20)
        }
        .frame(height: SettingsStage.height)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    /// The first two steps play a little loop; the others hold still.
    private var cycles: Bool {
        !reduceMotion && (tour.step == .notch || tour.step == .highlights)
    }

    private func scene(tick: Int) -> (pose: ModelNotch.Pose, caption: String) {
        switch tour.step {
        case .notch:
            let story: [(ModelNotch.Pose, String)] = [
                (.closed(.idle), "At rest, it's just the notch"),
                (.hovering, "Point at it…"),
                (.open(.home), "…and it opens"),
                (.closed(.music, secondary: .timer), "Closed, it shows what's going on"),
            ]
            return story[(reduceMotion ? 2 : tick) % story.count]
        case .highlights:
            let samples = Self.highlights
            return samples[tick % samples.count]
        case .permissions:
            let items = permissions.essentials
            let granted = items.filter { $0.state == .granted }.count
            let notice = LiveNotice(key: "permissions", symbol: granted == items.count ? "checkmark.shield.fill" : "lock.shield.fill",
                                    tint: granted == items.count ? .green : .orange, text: "\(granted)/\(items.count)")
            return (.closed(.notice(notice)), "\(granted) of \(items.count) allowed")
        case .done:
            return (.open(.home), "The Nook: your music and two widgets")
        }
    }

    @MainActor private static let highlights: [(ModelNotch.Pose, String)] = [
        (.closed(.timer, secondary: .music), "Two at once"),
        (.closed(.notice(NotificationPeek.sample())), "Notification peeks"),
        (.closed(.countdown(Countdown(id: UUID(), name: "Tea", duration: 240, pausedRemaining: 221)), secondary: .timer),
         "Named timers"),
        (.closed(.download, secondary: .music), "Downloads"),
        (.closed(.idle, secondary: .micMuted), "Muted microphone"),
        (.closed(.notice(LiveNotice(key: "rain", symbol: "cloud.rain.fill", tint: .cyan, text: "in 15m",
                                    detail: "Rain starting soon"))), "Rain alerts"),
    ]
}

// MARK: Steps

/// A symbol, a name and a line about it, on a card.
private struct InfoTile: Identifiable {
    let symbol: String
    let title: String
    let detail: String
    /// The badge's color. Without one, the window accent.
    var tint: Color?

    var id: String { title }
}

private struct InfoTileView: View {
    let tile: InfoTile

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SymbolBadge(symbol: tile.symbol, tint: tile.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(tile.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(tile.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(CardBackground())
        .accessibilityElement(children: .combine)
    }
}

private struct NotchStep: View {
    private let ways = [
        InfoTile(symbol: "cursorarrow.rays", title: "Hover", detail: "Rest the pointer for a glance at what's live"),
        InfoTile(symbol: "cursorarrow.click.2", title: "Click", detail: "Opens the whole notch"),
        InfoTile(symbol: "rectangle.and.hand.point.up.left.fill", title: "Swipe",
                 detail: "Two fingers down to open, up to close"),
        InfoTile(symbol: "command", title: "⌃⌥N", detail: "Opens or closes it from anywhere"),
    ]

    private let activities: [(symbol: String, title: String, tint: Color)] = [
        ("music.note", "Music", Palette.magenta),
        ("timer", "Timers", PomodoroTimer.Phase.focus.color),
        ("bolt.fill", "Charging", .green),
        ("speaker.wave.2.fill", "Volume", Color(red: 0.36, green: 0.56, blue: 1.0)),
        ("calendar", "Events", .orange),
        ("arrow.down.circle.fill", "Downloads", DownloadMonitor.tint),
        ("message.fill", "Messages", .green),
        ("moon.fill", "Focus", .indigo),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            SettingsSection(title: "Opening it", footer: "Swipe two fingers sideways over the notch to skip a track, or over the open notch to change tabs. Esc or moving away closes it.") {
                TileGrid(items: ways, columns: 4) { InfoTileView(tile: $0) }
            }
            SettingsSection(title: "Beside the camera",
                            footer: "With the notch closed, live activities show up beside the camera, and a second one can keep a small glyph at the end of the right ear.") {
                FlowLayout(spacing: 7) {
                    ForEach(activities, id: \.title) { activity in
                        HStack(spacing: 6) {
                            Image(systemName: activity.symbol)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(activity.tint)
                            Text(activity.title)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 11)
                        .frame(height: 28)
                        .background(Capsule().fill(Palette.wash))
                        .overlay(Capsule().strokeBorder(Palette.rimGradient))
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CardBackground())
            }
        }
    }
}

private struct HighlightsStep: View {
    private let highlights = [
        InfoTile(symbol: "rectangle.dashed.badge.record", title: "Capture",
                 detail: "⌃⌥S freezes the screen: select a region, mark it up, then copy, save or pin it", tint: .purple),
        InfoTile(symbol: "magnifyingglass", title: "Command field",
                 detail: "⌃⌥K: start a timer, add a note or a reminder, work out a sum", tint: Palette.lavender),
        InfoTile(symbol: "mic.slash.fill", title: "Mute and on air",
                 detail: "⌃⌥M mutes the mic in every app; a ring shows while a camera or mic is in use", tint: .red),
        InfoTile(symbol: "hourglass", title: "Timers",
                 detail: "Type “tea 4m” for a named timer, or run a stopwatch", tint: TimerStore.tint),
        InfoTile(symbol: "bell.badge.fill", title: "Notification peeks",
                 detail: "Messages, Mail, Slack and more slide out of the notch", tint: .indigo),
        InfoTile(symbol: "square.stack.3d.up.fill", title: "Profiles",
                 detail: "Work, Home, Presenting: switch the whole setup at once", tint: .teal),
        InfoTile(symbol: "cloud.sun.rain.fill", title: "Weather and notes",
                 detail: "Rain alerts, and notes that sync through iCloud Drive", tint: .blue),
        InfoTile(symbol: "minus", title: "Line notch",
                 detail: "On a display without a notch, a faint line that only grows when needed", tint: .gray),
    ]

    var body: some View {
        SettingsSection(title: "Highlights",
                        footer: "Also new: black or glass themes in your accent color, the volume and brightness keys without the system's HUD, an equalizer that follows the music, an output switcher, Quick Look and screenshots in the Tray, connecting Bluetooth devices from the Control tab, and a second activity as a glyph in the right ear.") {
            TileGrid(items: highlights, columns: 4) { InfoTileView(tile: $0) }
        }
    }
}

private struct PermissionsStep: View {
    @ObservedObject private var status = PermissionStatus.shared

    var body: some View {
        SettingsSection(title: "Worth allowing",
                        footer: "Full Disk Access has no prompt: in the list that opens, turn on Dynotch, adding it with + if it isn't there.") {
            SettingsCard {
                ForEach(Array(status.essentials.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { CardDivider() }
                    PermissionRow(item: item)
                }
            }
        }
        .task {
            await status.refreshAutomation()
            // Full Disk Access is turned on in System Settings, so look again while this step is up.
            while !Task.isCancelled, !NotificationMirror.shared.hasAccess {
                try? await Task.sleep(for: .seconds(2))
                NotificationMirror.shared.refreshAccess()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await status.refreshAutomation() }
        }
    }
}

private struct DoneStep: View {
    @ObservedObject var tour: WelcomeTour

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            SettingsSection(title: "Where things are") {
                SettingsCard {
                    row(symbol: "menubar.rectangle", tint: Palette.lavender, title: "The menu bar icon",
                        detail: "Profiles, the Tray, the focus timer and Settings, a click away")
                    CardDivider()
                    row(symbol: "gearshape.fill", tint: .gray, title: "Settings",
                        detail: "From the menu bar icon, or the ··· menu in the open notch") {
                        CapsuleButton(title: "Open Settings", symbol: "arrow.up.forward") {
                            tour.finish()
                            SettingsWindowController.shared.show(page: .general)
                        }
                    }
                    CardDivider()
                    row(symbol: "sparkles", tint: .orange, title: "This tour",
                        detail: "Settings → About, or Welcome Tour in the menu bar menu")
                }
            }
            SettingsSection(title: "Try it") {
                HStack(spacing: 12) {
                    SymbolBadge(symbol: "hand.point.up.left.fill", tint: Palette.magenta, size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Point at the notch, or press ⌃⌥N")
                            .font(.system(size: 13, weight: .medium))
                        Text("Move away, or press Esc, and it closes again.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 12)
                    CapsuleButton(title: "Open the Notch", symbol: "arrow.up.forward") {
                        NotchManager.shared.open(tab: .home)
                    }
                }
                .padding(14)
                .background(CardBackground())
            }
        }
    }

    private func row(symbol: String, tint: Color, title: String, detail: String,
                     @ViewBuilder trailing: () -> some View = { EmptyView() }) -> some View {
        HStack(spacing: 12) {
            SymbolBadge(symbol: symbol, tint: tint, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.secondaryText)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: Footer

private struct WelcomeFooter: View {
    @ObservedObject var tour: WelcomeTour
    @Environment(\.windowAccent) private var accent

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(WelcomeTour.Step.allCases) { step in
                    Capsule()
                        .fill(step == tour.step ? AnyShapeStyle(accent.gradient) : AnyShapeStyle(Palette.track))
                        .frame(width: step == tour.step ? 20 : 7, height: 7)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Step \(tour.step.rawValue + 1) of \(WelcomeTour.Step.allCases.count)")
            Spacer(minLength: 0)
            if tour.step != .notch {
                CapsuleButton(title: "Back") { tour.back() }
                    .transition(.opacity)
            }
            CapsuleButton(title: tour.step == .done ? "Start Using Dynotch" : "Continue", kind: .prominent) { tour.next() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 26)
        .frame(height: 64)
        .background(Palette.sidebar)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.stroke).frame(height: 1)
        }
    }
}

// MARK: Permissions

extension PermissionStatus {
    /// The permissions worth giving on day one, for the welcome tour: the players, the calendar,
    /// Bluetooth, the Downloads folder and Full Disk Access. The others are asked for when the
    /// feature that needs them is turned on.
    var essentials: [Item] {
        let wanted: Set = ["Calendar", "Reminders", "Bluetooth", "Downloads folder", "Full Disk Access"]
        let players = automationItems.filter { item in
            item.title == "Music" || (item.title == "Spotify" && NowPlayingService.Player.spotify.isInstalled)
        }
        return players + privacy.filter { wanted.contains($0.title) }
    }
}
