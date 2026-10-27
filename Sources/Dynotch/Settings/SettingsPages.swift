import AppKit
import ServiceManagement
import SwiftUI

/// An on/off setting, shown as a tile.
struct SwitchOption: Identifiable {
    let title: String
    let detail: String
    let symbol: String
    var tint: Color = Palette.accent
    var spokenTitle: String?
    let setting: ReferenceWritableKeyPath<AppSettings, Bool>

    var id: String { title }
}

/// Tiles in rows of `columns`; the tiles in a row share the tallest one's height.
struct TileGrid<Item: Identifiable, Tile: View>: View {
    let items: [Item]
    var columns = 2
    @ViewBuilder let tile: (Item) -> Tile

    var body: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            ForEach(Array(stride(from: 0, to: items.count, by: columns)), id: \.self) { start in
                GridRow {
                    ForEach(items[start..<min(start + columns, items.count)]) { item in
                        tile(item)
                    }
                }
            }
        }
    }
}

/// Switch tiles for settings on `AppSettings`.
private struct SwitchGrid: View {
    let options: [SwitchOption]
    var columns = 2
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        TileGrid(items: options, columns: columns) { option in
            SwitchTile(title: option.title, detail: option.detail, symbol: option.symbol, tint: option.tint,
                       spokenTitle: option.spokenTitle, isOn: $settings[dynamicMember: option.setting])
        }
    }
}

/// A slider with its name and value, as a row in a card. `spokenTitle` is what VoiceOver
/// reads when the visible name leans on its section, like a second "Width".
private struct SliderRow: View {
    let title: String
    var spokenTitle: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    let spoken: (Double) -> String

    var body: some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 88, alignment: .leading)
                .accessibilityHidden(true)
            TrackSlider(title: spokenTitle ?? title, value: $value, range: range, step: step, spokenValue: spoken(value))
            Text(format(value))
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
    }
}

private func points(_ value: Double) -> String { "\(Int(value)) pt" }
private func spokenPoints(_ value: Double) -> String { "\(Int(value)) points" }

// MARK: General

struct GeneralSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    private let openers = [
        SwitchOption(title: "Hover", detail: "Open when the pointer rests on the notch", symbol: "cursorarrow.rays",
                     setting: \.openOnHover),
        SwitchOption(title: "Swipe", detail: "Swipe down on the trackpad to open, up to close",
                     symbol: "rectangle.and.hand.point.up.left.fill",
                     setting: \.swipeGestures),
        SwitchOption(title: "Keyboard shortcut", detail: "Toggle the notch with ⌃⌥N", symbol: "command",
                     setting: \.globalShortcut),
        SwitchOption(title: "Haptic feedback", detail: "A tap from the trackpad when the notch responds",
                     symbol: "hand.tap.fill", setting: \.haptics),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            SettingsSection(title: "Opening the notch") {
                SwitchGrid(options: openers)
                if settings.openOnHover {
                    SettingsCard {
                        SliderRow(title: "Hover delay", value: $settings.hoverDelay, range: 0...1, step: 0.05,
                                  format: { String(format: "%.2f s", $0) },
                                  spoken: { String(format: "%.2f seconds", $0) })
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: settings.openOnHover)

            SettingsSection(title: "Show the notch on",
                            footer: "Displays without a notch get a virtual one that hangs from the top edge.") {
                HStack(spacing: 10) {
                    ForEach(DisplayMode.allCases) { mode in
                        ChoiceTile(title: mode.title, isSelected: settings.displayMode == mode) {
                            settings.displayMode = mode
                        } art: {
                            DisplaysArt(mode: mode, isSelected: settings.displayMode == mode)
                        }
                    }
                }
            }

            SettingsSection(title: "App") {
                SettingsCard {
                    LaunchAtLoginRow()
                    CardDivider()
                    SwitchRow(title: "Show menu bar icon", detail: "Settings, the tray and the timer, a click away",
                              symbol: "menubar.rectangle", isOn: $settings.showMenuBarIcon)
                }
            }
        }
    }
}

private struct LaunchAtLoginRow: View {
    @ViewState private var isEnabled = SMAppService.mainApp.status == .enabled
    @ViewState private var message: String?

    var body: some View {
        SwitchRow(title: "Launch at login", detail: message ?? "Start Dynotch when you log in", symbol: "power",
                  isOn: Binding(get: { isEnabled }, set: { enable in
            do {
                if enable {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                message = SMAppService.mainApp.status == .requiresApproval
                    ? "Allow Dynotch in System Settings → General → Login Items." : nil
            } catch {
                message = error.localizedDescription
            }
            isEnabled = SMAppService.mainApp.status == .enabled
        }))
    }
}

/// A laptop and a monitor, with a notch on each display the mode covers.
private struct DisplaysArt: View {
    let mode: DisplayMode
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 7) {
            Screen(width: 34, height: 22, hasNotch: mode != .main, isLaptop: true)
            Screen(width: 30, height: 20, hasNotch: mode != .notched, isLaptop: false)
        }
        .foregroundStyle(isSelected ? Palette.accent : Color.secondary)
    }

    private struct Screen: View {
        let width: CGFloat
        let height: CGFloat
        let hasNotch: Bool
        let isLaptop: Bool

        var body: some View {
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(lineWidth: 1.6)
                    .frame(width: width, height: height)
                    .overlay(alignment: .top) {
                        if hasNotch {
                            NotchShape(topRadius: 1.5, bottomRadius: 2)
                                .frame(width: width * 0.36, height: 4.5)
                        }
                    }
                if isLaptop {
                    Capsule().frame(width: width + 8, height: 2.5)
                } else {
                    Rectangle().frame(width: 2, height: 4)
                    Capsule().frame(width: 13, height: 2)
                }
            }
            .opacity(hasNotch ? 1 : 0.4)
        }
    }
}

// MARK: Appearance

struct AppearanceSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    private let style = [
        SwitchOption(title: "Artwork tint", detail: "Color the player with the album art's color", symbol: "paintpalette.fill",
                     tint: Palette.magenta, setting: \.artworkTint),
        SwitchOption(title: "Shadow", detail: "A soft shadow under the open notch", symbol: "square.2.layers.3d.bottom.filled",
                     tint: Palette.indigo, setting: \.showOpenShadow),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            SettingsSection(title: "Open notch") {
                SettingsCard {
                    SliderRow(title: "Width", spokenTitle: "Open notch width", value: $settings.openWidth,
                              range: 600...840, step: 10,
                              format: points, spoken: spokenPoints)
                    CardDivider()
                    SliderRow(title: "Height", spokenTitle: "Open notch height", value: $settings.openHeight,
                              range: 196...260, step: 2,
                              format: points, spoken: spokenPoints)
                }
            }
            SettingsSection(title: "Virtual notch", footer: "Used on displays without a camera notch.") {
                SettingsCard {
                    VirtualNotchSketch(width: settings.virtualNotchWidth)
                    CardDivider()
                    SliderRow(title: "Width", spokenTitle: "Virtual notch width", value: $settings.virtualNotchWidth,
                              range: 140...280, step: 5,
                              format: points, spoken: spokenPoints)
                }
            }
            SettingsSection(title: "Style") {
                SwitchGrid(options: style)
            }
        }
    }
}

/// The top of an external display with the virtual notch hanging from it, at half size.
private struct VirtualNotchSketch: View {
    let width: Double

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.36, green: 0.52, blue: 0.86), Color(red: 0.86, green: 0.55, blue: 0.62)],
                           startPoint: .leading, endPoint: .trailing)
                .opacity(0.85)
            Rectangle().fill(.white.opacity(0.5)).frame(height: 12)
            NotchShape(topRadius: 3, bottomRadius: 6)
                .fill(.black)
                .frame(width: width / 2 + 6, height: 14)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: width)
        }
        .frame(height: 44)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 13, topTrailingRadius: 13, style: .continuous))
        .padding([.horizontal, .top], 1)
        .accessibilityHidden(true)
    }
}

// MARK: Live activities

/// The live activities that can be turned off, and a sample of each for the preview.
enum LiveActivityKind: String, CaseIterable, Identifiable {
    case music, trackPeek, timer, levels, charging, lowBattery, events, devices
    case notifications

    var id: String { rawValue }

    var title: String {
        switch self {
        case .music: "Now playing"
        case .trackPeek: "Track changes"
        case .timer: "Focus timer"
        case .levels: "Volume & brightness"
        case .charging: "Charging"
        case .lowBattery: "Low battery"
        case .events: "Upcoming events"
        case .devices: "Bluetooth devices"
        case .notifications: "Notifications"
        }
    }

    var detail: String {
        switch self {
        case .music: "Artwork and an equalizer while music plays"
        case .trackPeek: "The song's name when the track changes"
        case .timer: "A countdown while the timer runs"
        case .levels: "A meter as you change them"
        case .charging: "The battery level when you plug in"
        case .lowBattery: "For the Mac and Bluetooth devices"
        case .events: "Five minutes before they start"
        case .devices: "When one connects, with its battery"
        case .notifications: "Messages, Mail, Slack and more as they arrive"
        }
    }

    var symbol: String {
        switch self {
        case .music: "music.note"
        case .trackPeek: "music.note.list"
        case .timer: "timer"
        case .levels: "speaker.wave.2.fill"
        case .charging: "bolt.fill"
        case .lowBattery: "battery.25percent"
        case .events: "calendar"
        case .devices: "airpodspro"
        case .notifications: "bell.badge.fill"
        }
    }

    var tint: Color {
        switch self {
        case .music: Palette.magenta
        case .trackPeek: Palette.lavender
        case .timer: PomodoroTimer.Phase.focus.color
        case .levels: Color(red: 0.36, green: 0.56, blue: 1.0)
        case .charging: .green
        case .lowBattery: .red
        case .events: .orange
        case .devices: .teal
        case .notifications: .indigo
        }
    }

    @MainActor
    var setting: ReferenceWritableKeyPath<AppSettings, Bool> {
        switch self {
        case .music: \.liveMusic
        case .trackPeek: \.trackPeek
        case .timer: \.liveTimer
        case .levels: \.liveHUD
        case .charging: \.liveCharging
        case .lowBattery: \.lowBatteryAlerts
        case .events: \.liveEvents
        case .devices: \.liveDevices
        case .notifications: \.liveNotifications
        }
    }

    /// The song's name only shows while Now playing is on.
    @MainActor
    func isShown(with settings: AppSettings) -> Bool {
        settings[keyPath: setting] && (self != .trackPeek || settings.liveMusic)
    }

    var sample: ClosedActivity {
        switch self {
        case .music: .music
        case .trackPeek: .trackPeek
        case .timer: .timer
        case .levels: .notice(LiveNotice(key: "volume", symbol: "speaker.wave.2.fill", tint: .white, kind: .meter(0.62)))
        case .charging: .notice(LiveNotice(key: "power", symbol: "bolt.fill", tint: .green, text: "82%"))
        case .lowBattery:
            .notice(LiveNotice(key: "power", symbol: "battery.25percent", tint: .red, text: "10%",
                               detail: "Low battery. Plug in soon."))
        case .events: .notice(LiveNotice(key: "event", symbol: "calendar", tint: .orange, text: "in 5m", detail: "Design review"))
        case .devices:
            .notice(LiveNotice(key: "device", symbol: "airpodspro", tint: .white, text: "80%", detail: "AirPods Pro connected"))
        case .notifications: .notice(NotificationPeek.sample())
        }
    }
}

struct ActivitySettings: View {
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject private var settings = AppSettings.shared

    /// The activities, then a tile that shows a sample in the real notch.
    private enum Tile: Identifiable {
        case activity(LiveActivityKind)
        case preview

        var id: String {
            switch self {
            case .activity(let kind): kind.rawValue
            case .preview: "preview"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            activities
            if settings.liveNotifications {
                NotificationSettingsSection()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: settings.liveNotifications)
    }

    @ViewBuilder
    private var activities: some View {
        let onCount = LiveActivityKind.allCases.filter { settings[keyPath: $0.setting] }.count
        SettingsSection(title: "Show in the closed notch", trailing: "\(onCount) of \(LiveActivityKind.allCases.count) on",
                        footer: "Live activities appear beside the camera without opening the notch. Point at one to see it above.") {
            TileGrid(items: LiveActivityKind.allCases.map(Tile.activity) + [.preview], columns: 3) { tile in
                switch tile {
                case .activity(let kind):
                    activityTile(kind)
                case .preview:
                    ActionTile(title: "Preview", detail: "Show a sample in the notch", symbol: "sparkles") {
                        LiveActivityCenter.shared.post(LiveNotice(key: "preview", symbol: "sparkles", tint: .yellow, text: "Hi!",
                                                                  detail: "This is a live activity"), for: 3)
                    }
                }
            }
        }
    }

    private func activityTile(_ kind: LiveActivityKind) -> some View {
        let needsMusic = kind == .trackPeek && !settings.liveMusic
        return SwitchTile(title: kind.title, detail: needsMusic ? "Needs Now playing" : kind.detail,
                          symbol: kind.symbol, tint: kind.tint, isOn: $settings[dynamicMember: kind.setting])
            .disabled(needsMusic)
            .onHover { inside in
                if inside {
                    navigation.spotlight = kind
                } else if navigation.spotlight == kind {
                    navigation.spotlight = nil
                }
            }
    }
}

// MARK: Nook

struct NookSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    private let tabs = [
        SwitchOption(title: "Tray", detail: "Files you're working with", symbol: NotchTab.tray.symbol,
                     tint: .teal, spokenTitle: "Tray tab", setting: \.showTrayTab),
        SwitchOption(title: "Focus", detail: "Timer, reminders and notes", symbol: NotchTab.focus.symbol,
                     tint: PomodoroTimer.Phase.focus.color, spokenTitle: "Focus tab", setting: \.showFocusTab),
        SwitchOption(title: "Stats", detail: "System, batteries and toggles", symbol: NotchTab.stats.symbol,
                     tint: Color(red: 0.36, green: 0.56, blue: 1.0), spokenTitle: "Stats tab", setting: \.showStatsTab),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            SettingsSection(title: "Tabs", footer: "The Nook tab, with the player, is always there.") {
                SwitchGrid(options: tabs, columns: 3)
            }
            SettingsSection(title: "Next to the player") {
                HStack(alignment: .top, spacing: 10) {
                    WidgetSlotPicker(title: "First widget", selection: $settings.homeWidgetA)
                    WidgetSlotPicker(title: "Second widget", selection: $settings.homeWidgetB)
                }
            }
            SettingsSection(title: "The play button starts",
                            footer: "Dynotch follows Apple Music and Spotify. macOS keeps other players' Now Playing info private to Apple's own apps.") {
                HStack(spacing: 10) {
                    ForEach(PlayerChoice.allCases) { player in
                        ChoiceTile(title: player.title, isSelected: settings.preferredPlayer == player) {
                            settings.preferredPlayer = player
                        } art: {
                            AppIconView(bundleID: player == .music ? "com.apple.Music" : "com.spotify.client",
                                        fallback: "music.note", side: 34)
                        }
                    }
                }
            }
            SettingsSection(title: "Calendar") {
                SettingsCard {
                    SwitchRow(title: "Show all-day events", detail: "List them in the Calendar widget",
                              symbol: "sun.max.fill", tint: .orange, isOn: $settings.showAllDayEvents)
                }
                .onChange(of: settings.showAllDayEvents) { CalendarService.shared.reload() }
            }
            SettingsSection(title: "Pinned shortcuts", trailing: "\(settings.pinnedShortcuts.count) of 4",
                            footer: "Pin up to four. They show in the Shortcuts widget.") {
                ShortcutPins()
            }
        }
    }
}

/// Picks the widget for one of the two places beside the player.
private struct WidgetSlotPicker: View {
    let title: String
    @Binding var selection: HomeWidget

    private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.leading, 2)
                .accessibilityHidden(true)
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(HomeWidget.allCases) { widget in
                    ChoiceChip(title: widget.title, symbol: widget.symbol, isSelected: selection == widget) {
                        selection = widget
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

private struct ShortcutPins: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var shortcuts = ShortcutsService.shared

    var body: some View {
        // Pinned shortcuts that no longer exist stay listed, so they can be unpinned.
        let names = shortcuts.all + settings.pinnedShortcuts.filter { !shortcuts.all.contains($0) }
        Group {
            if names.isEmpty {
                Text("No shortcuts found.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                FlowLayout(spacing: 7) {
                    ForEach(names, id: \.self) { name in
                        let isPinned = settings.pinnedShortcuts.contains(name)
                        PinChip(title: name, isPinned: isPinned) {
                            if isPinned {
                                settings.pinnedShortcuts.removeAll { $0 == name }
                            } else {
                                settings.pinnedShortcuts.append(name)
                            }
                        }
                        .disabled(!isPinned && settings.pinnedShortcuts.count >= 4)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground())
        .task { await shortcuts.reload() }
    }
}

private struct PinChip: View {
    let title: String
    let isPinned: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 9.5, weight: .bold))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isPinned ? Color.white : Color.primary.opacity(0.8))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(isPinned ? AnyShapeStyle(Palette.buttonGradient) : AnyShapeStyle(Palette.wash)))
            .contentShape(Capsule())
        }
        .buttonStyle(TileButtonStyle(cornerRadius: 13))
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(title)
        .accessibilityValue(isPinned ? "Pinned" : "Not pinned")
        .accessibilityAddTraits(.isToggle)
    }
}

/// An app's icon from its bundle ID, or a symbol if the app isn't installed.
struct AppIconView: View {
    let bundleID: String
    let fallback: String
    let side: CGFloat

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: IconCache.icon(forFile: url.path, side: side))
                .resizable()
                .frame(width: side, height: side)
                .accessibilityHidden(true)
        } else {
            SymbolBadge(symbol: fallback, tint: .gray, size: side * 0.85)
        }
    }
}

// MARK: Tray

struct TraySettings: View {
    @ObservedObject private var tray = TrayStore.shared

    private let options = [
        SwitchOption(title: "Open on drag", detail: "Open the tray when files are dragged toward the notch",
                     symbol: "arrow.down.to.line", tint: .teal, setting: \.trayOpensOnDrag),
        SwitchOption(title: "Keep copies", detail: "The tray keeps its own copy of every dropped file",
                     symbol: "doc.on.doc.fill", tint: Color(red: 0.36, green: 0.56, blue: 1.0), setting: \.trayCopiesFiles),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            SettingsSection(title: "Dropping files",
                            footer: "With copies, the originals can be moved or deleted and the tray keeps its own. Copies go to the Trash when you remove them.") {
                SwitchGrid(options: options)
            }
            SettingsSection(title: "In the tray") {
                HStack(spacing: 16) {
                    FileStack(urls: Array(tray.urls.prefix(4)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tray.items.count == 1 ? "1 item" : "\(tray.items.count) items")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .contentTransition(.numericText(value: Double(tray.items.count)))
                        Text(tray.items.isEmpty ? "Drop files on the notch to park them here." : "Parked in the notch for later.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 10)
                    CapsuleButton(title: "Show Folder", symbol: "folder") { NSWorkspace.shared.open(tray.folder) }
                    CapsuleButton(title: "Clear Tray", symbol: "trash", kind: .destructive) { tray.clear() }
                        .disabled(tray.items.isEmpty)
                }
                .padding(14)
                .background(CardBackground())
            }
        }
    }
}

/// A few file icons fanned out like a hand of cards.
private struct FileStack: View {
    let urls: [URL]

    var body: some View {
        ZStack {
            if urls.isEmpty {
                SymbolBadge(symbol: "tray", isActive: false, size: 44)
            }
            ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                let offset = Double(index) - Double(urls.count - 1) / 2
                Image(nsImage: IconCache.icon(forFile: url.path, side: 40))
                    .resizable()
                    .frame(width: 40, height: 40)
                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                    .rotationEffect(.degrees(offset * 9))
                    .offset(x: offset * 13, y: abs(offset) * 2)
            }
        }
        .frame(width: 78, height: 50)
        .accessibilityHidden(true)
    }
}

// MARK: Focus timer

struct FocusSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    private let behavior = [
        SwitchOption(title: "Auto-start", detail: "Start the next phase automatically", symbol: "forward.fill",
                     tint: PomodoroTimer.Phase.shortBreak.color, setting: \.autoStartNextPhase),
        SwitchOption(title: "Sound", detail: "Play a sound when a phase ends", symbol: "bell.fill",
                     tint: .orange, setting: \.timerSound),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            SettingsSection(title: "Durations", trailing: "A round takes \(Self.roundLength(settings))") {
                HStack(spacing: 10) {
                    NumberDial(title: "Focus", value: $settings.focusMinutes, range: 5...120, step: 5, unit: "min",
                               tint: PomodoroTimer.Phase.focus.color)
                    NumberDial(title: "Short break", value: $settings.shortBreakMinutes, range: 1...30, unit: "min",
                               tint: PomodoroTimer.Phase.shortBreak.color)
                    NumberDial(title: "Long break", value: $settings.longBreakMinutes, range: 5...60, step: 5, unit: "min",
                               tint: PomodoroTimer.Phase.longBreak.color)
                    NumberDial(title: "Long break after", value: $settings.sessionsPerRound, range: 2...8,
                               unit: "sessions", tint: Palette.accent)
                }
            }
            SettingsSection(title: "Behavior") {
                SwitchGrid(options: behavior)
            }
        }
    }

    /// Focus sessions, the short breaks between them and the long break at the end: "2 h 10 min".
    static func roundLength(_ settings: AppSettings) -> String {
        let sessions = settings.sessionsPerRound
        let minutes = sessions * settings.focusMinutes + (sessions - 1) * settings.shortBreakMinutes + settings.longBreakMinutes
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest) min" }
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}

// MARK: About

struct AboutSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(spacing: 14) {
                DynotchLogo(size: 92)
                    .shadow(color: Palette.lavender.opacity(0.45), radius: 18, y: 6)
                VStack(spacing: 3) {
                    Text("Dynotch")
                        .font(.system(size: 26, weight: .bold))
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text("Music, files, your calendar, a focus timer and more, one hover away.")
                    .font(.system(size: 13))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                Text("Inspired by NotchNook and MacNotch.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity)
            .background(CardBackground())

            SettingsSection(title: "Keyboard") {
                SettingsCard {
                    ShortcutRow(keys: ["⌃", "⌥", "N"], spokenKeys: "Control Option N", action: settings.globalShortcut
                        ? "Open or close the notch" : "Open or close the notch (turned off in General)")
                    CardDivider()
                    ShortcutRow(keys: ["⌘", "1 – 8"], spokenKeys: "Command 1 to 8", action: "Jump to a page of these settings")
                    CardDivider()
                    ShortcutRow(keys: ["↑", "↓"], spokenKeys: "Up or down arrow",
                                action: "Move through the pages, once the sidebar is selected")
                }
            }
        }
    }
}

private struct ShortcutRow: View {
    let keys: [String]
    let spokenKeys: String
    let action: String

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 7)
                        .frame(minWidth: 24, minHeight: 24)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.wash))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.stroke))
                }
            }
            .frame(width: 104, alignment: .leading)
            Text(action)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(spokenKeys): \(action)")
        .accessibilityAddTraits(.isStaticText)
    }
}
