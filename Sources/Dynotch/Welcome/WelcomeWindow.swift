import AppKit
import SwiftUI

/// The tour a new user sees on first launch, in place of Settings: what the notch does, what's
/// new, the permissions worth giving, and where things are. Settings → About and the menu bar
/// menu bring it back.
@MainActor
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    static let shared = WelcomeWindowController()
    static let contentSize = NSSize(width: 840, height: 700)
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
            case .notch: "Point at the notch to see what’s live"
            case .highlights: "What's new"
            case .permissions: "Permissions"
            case .done: "You're all set"
            }
        }

        var subtitle: String {
            switch self {
            case .notch: "It opens on Live: what’s happening now, most urgent first. Your sections sit under it, and the command field is at its foot."
            case .highlights: "A few of the things this version brings to the notch."
            case .permissions: "Allow what you'd like now. The rest is asked for when a feature first needs it."
            case .done: "Dynotch lives in the notch and in the menu bar."
            }
        }

        /// The button that moves on, saying where to.
        var next: String {
            switch self {
            case .notch: "Next: what’s new"
            case .highlights: "Next: permissions"
            case .permissions: "Next: where things are"
            case .done: "Start using Dynotch"
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
/// Everything in it draws in Orbit's colors and the user's accent, as Settings does.
struct WelcomeView: View {
    @ObservedObject var tour: WelcomeTour
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            WelcomeStage(tour: tour)
            ScrollView {
                content
                    .padding(.horizontal, 40)
                    .padding(.top, 18)
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
        .orbitWindow(settings)
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
    @Environment(\.windowAccent) private var accent

    private static let cycle: TimeInterval = 2.2
    private static let deskHeight: CGFloat = 170

    var body: some View {
        let step = tour.step
        VStack(alignment: .leading, spacing: 0) {
            // Beside the window's buttons: how far along the tour is.
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                ForEach(WelcomeTour.Step.allCases) { item in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(item == step ? accent.fill : Palette.track)
                        .frame(width: 28, height: 4)
                }
            }
            .frame(height: 24)
            .padding(.top, 12)
            .accessibilityElement()
            .accessibilityLabel("Step \(step.rawValue + 1) of \(WelcomeTour.Step.allCases.count)")
            StageDesk(menuBarHeight: 22) {
                TimelineView(.periodic(from: .now, by: cycles ? Self.cycle : 3600)) { context in
                    let tick = isSnapshot ? 2 : Int(context.date.timeIntervalSinceReferenceDate / Self.cycle)
                    let scene = scene(tick: tick)
                    ZStack(alignment: .top) {
                        ModelNotch(pose: scene.pose, openScale: 0.4, openHeight: Self.deskHeight - 8)
                        CaptionText(scene.caption, isNumeric: false)
                            .padding(.leading, 14)
                            .padding(.bottom, 12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    }
                    .animation(reduceMotion ? .easeOut(duration: 0.2) : .notchOpen, value: scene.pose)
                }
                .animation(reduceMotion ? .easeOut(duration: 0.2) : .notchOpen, value: step)
            }
            .frame(height: Self.deskHeight)
            .padding(.top, 14)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(step.title)
                    .font(.system(size: 28, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)
                Text(step.subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.secondaryText)
                    .lineSpacing(2)
                    .frame(maxWidth: 600, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .id(step)
            .transition(.opacity)
            .padding(.top, 22)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity)
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
                (.open(.live), "…and it opens on Live"),
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
            return (.open(.live), "Live on top, your sections under it")
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

/// A key, what it does, and a line about it, on a card.
private struct KeyTile: View {
    let keys: String
    let title: String
    let detail: String
    @Environment(\.notchTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(keys)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.secondaryText)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Palette.stroke))
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .padding(.top, 10)
            Text(detail)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.secondaryText)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.controlShape.fill(Palette.cardTop).overlay(theme.controlShape.strokeBorder(Palette.stroke)))
        .accessibilityElement(children: .combine)
    }
}

private struct NotchStep: View {
    private struct Key: Identifiable {
        let keys: String
        let title: String
        let detail: String
        var id: String { keys }
    }

    private let keys = [
        Key(keys: "⌃⌥N", title: "Open or close", detail: "Or point at the notch; move away to close."),
        Key(keys: "⌃⌥K", title: "Type a command", detail: "tea 4m, note Buy coffee, tray."),
        Key(keys: "⌃⌥S", title: "Capture the screen", detail: "A window, a region or a display."),
    ]

    private let ways = [
        InfoTile(symbol: "cursorarrow.rays", title: "Hover", detail: "Rest the pointer on it to see what's live"),
        InfoTile(symbol: "cursorarrow.click.2", title: "Click", detail: "Opens the whole notch"),
        InfoTile(symbol: "rectangle.and.hand.point.up.left.fill", title: "Swipe",
                 detail: "Two fingers down to open, up to close"),
        InfoTile(symbol: "rectangle.bottomhalf.inset.filled", title: "Sections",
                 detail: "Buttons under the panel; each shows its live figure"),
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

    @Environment(\.notchTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            TileGrid(items: keys, columns: 3) { KeyTile(keys: $0.keys, title: $0.title, detail: $0.detail) }
            SettingsSection(title: "Opening it", footer: "Swipe two fingers sideways over the notch to skip a track, or over the open notch to change sections. Esc or moving away closes it.") {
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
                        .background(theme.controlShape.fill(Palette.wash))
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
                        footer: "Also new: a light or dark notch in your accent color, the volume and brightness keys without the system's HUD, an equalizer that follows the music, an output switcher, Quick Look and screenshots in the Tray, connecting Bluetooth devices from the Control section, and a second activity as a glyph in the right ear.") {
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
                        NotchManager.shared.open(tab: .live)
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

/// Back, Skip tour and the button that moves on, at the window's foot.
private struct WelcomeFooter: View {
    @ObservedObject var tour: WelcomeTour

    var body: some View {
        HStack(spacing: 8) {
            if tour.step != .notch {
                CapsuleButton(title: "Back") { tour.back() }
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
            if tour.step != .done {
                CapsuleButton(title: "Skip tour", kind: .glass) { tour.finish() }
                    .transition(.opacity)
            }
            WelcomeNextButton(title: tour.step.next) { tour.next() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 40)
        .frame(height: 64)
        .background(Palette.window)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.stroke).frame(height: 1)
        }
    }
}

/// The tour's large focus button.
private struct WelcomeNextButton: View {
    let title: String
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            FocusButtonLabel(title: title, height: 36, hovering: hovering)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.97))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(title)
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
