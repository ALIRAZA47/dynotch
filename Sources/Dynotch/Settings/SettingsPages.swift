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
        SwitchOption(title: "Hover", detail: "A glance, or the whole notch, when the pointer rests on it",
                     symbol: "cursorarrow.rays", setting: \.openOnHover),
        SwitchOption(title: "Swipe", detail: "Swipe down on the trackpad to open, up to close, sideways to skip a track or, once it's open, to change tabs",
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
                        HoverShowsRow()
                        CardDivider()
                        SliderRow(title: "Hover delay", value: $settings.hoverDelay, range: 0...1, step: 0.05,
                                  format: { String(format: "%.2f s", $0) },
                                  spoken: { String(format: "%.2f seconds", $0) })
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: settings.openOnHover)

            SettingsSection(title: "Command field",
                            footer: "Start a timer (tea 4m), add a note or a reminder (remind Call Sam 5pm), flip a toggle, "
                                + "switch a profile, run a shortcut or work out a sum. In the open notch, click Type a command.") {
                SettingsCard {
                    SwitchRow(title: "Open it with ⌃⌥K", detail: "From anywhere, ready to type", symbol: "magnifyingglass",
                              isOn: $settings.commandShortcut)
                }
            }

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

            ProfilesSection()

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

/// What resting the pointer on the notch brings up: a glance at what's live, or the whole notch.
private struct HoverShowsRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 14) {
            Text("Hover shows")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 88, alignment: .leading)
            HStack(spacing: 8) {
                ForEach(HoverShows.allCases) { choice in
                    ChoiceChip(title: choice.title, symbol: choice.symbol, isSelected: settings.hoverShows == choice) {
                        settings.hoverShows = choice
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
        SwitchOption(title: "Artwork tint", detail: "Color the player with the album art instead of the accent",
                     symbol: "paintpalette.fill", tint: Palette.magenta, setting: \.artworkTint),
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
            ThemeSettings()
            SettingsSection(title: "Style") {
                SwitchGrid(options: style)
            }
            SettingsSection(title: "Virtual notch", footer: virtualNotchFooter) {
                HStack(spacing: 10) {
                    ForEach(VirtualNotchStyle.allCases) { style in
                        ChoiceTile(title: style.title, detail: style.detail, isSelected: settings.virtualNotchStyle == style) {
                            settings.virtualNotchStyle = style
                        } art: {
                            VirtualNotchArt(style: style, isSelected: settings.virtualNotchStyle == style)
                        }
                    }
                }
                SettingsCard {
                    VirtualNotchSketch(width: settings.virtualNotchWidth, style: settings.virtualNotchStyle)
                    CardDivider()
                    SliderRow(title: "Width", spokenTitle: "Virtual notch width", value: $settings.virtualNotchWidth,
                              range: 140...280, step: 5,
                              format: points, spoken: spokenPoints)
                }
            }
        }
    }

    private var virtualNotchFooter: String {
        switch settings.virtualNotchStyle {
        case .notch:
            "Used on displays without a camera notch."
        case .line:
            "Used on displays without a camera notch. The line covers nothing: it grows into the notch while "
                + "something's showing, when you hover, and when it opens."
        }
    }
}

/// A monitor with the virtual notch, or just the line, along its top edge.
private struct VirtualNotchArt: View {
    let style: VirtualNotchStyle
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(lineWidth: 1.6)
                .frame(width: 40, height: 26)
                .overlay(alignment: .top) {
                    switch style {
                    case .notch:
                        NotchShape(topRadius: 1.5, bottomRadius: 2.5)
                            .frame(width: 16, height: 5.5)
                    case .line:
                        Capsule()
                            .frame(width: 14, height: 2)
                            .padding(.top, 2.6)
                    }
                }
            Rectangle().frame(width: 2, height: 4)
            Capsule().frame(width: 15, height: 2)
        }
        .foregroundStyle(isSelected ? Palette.accent : Color.secondary)
    }
}

/// The open notch's material, accent color and corners. The header above shows each change.
private struct ThemeSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            SettingsSection(title: "Material",
                            footer: "The closed notch stays black either way, so it blends with the camera housing.") {
                HStack(spacing: 10) {
                    ForEach(NotchMaterial.allCases) { material in
                        let isAvailable = material != .glass || NotchMaterial.isGlassAvailable
                        ChoiceTile(title: material.title, detail: detail(for: material, isAvailable: isAvailable),
                                   isSelected: settings.notchMaterial == material) {
                            settings.notchMaterial = material
                        } art: {
                            MaterialArt(material: material)
                        }
                        .disabled(!isAvailable)
                        .opacity(isAvailable ? 1 : 0.5)
                    }
                }
            }
            SettingsSection(title: "Accent color", trailing: settings.notchAccent.title,
                            footer: "For the selected tab, selections and buttons, and for the player while Artwork tint is off.") {
                AccentPicker(selection: $settings.notchAccent)
            }
            SettingsSection(title: "Corners", footer: "The cards inside the open notch round off with its bottom corners.") {
                SettingsCard {
                    SliderRow(title: "Top", spokenTitle: "Top corners", value: $settings.notchTopRadius,
                              range: Double(NotchTheme.topRadiusRange.lowerBound)...Double(NotchTheme.topRadiusRange.upperBound),
                              step: 1, format: points, spoken: spokenPoints)
                    CardDivider()
                    SliderRow(title: "Bottom", spokenTitle: "Bottom corners", value: $settings.notchBottomRadius,
                              range: Double(NotchTheme.bottomRadiusRange.lowerBound)...Double(NotchTheme.bottomRadiusRange.upperBound),
                              step: 1, format: points, spoken: spokenPoints)
                }
            }
        }
    }

    private func detail(for material: NotchMaterial, isAvailable: Bool) -> String {
        switch material {
        case .black: "Like the camera housing"
        case .glass: isAvailable ? "See the desktop through it" : "Needs macOS 26 or later"
        }
    }
}

/// A strip of desktop with an open notch hanging from it, black or glass.
private struct MaterialArt: View {
    let material: NotchMaterial

    var body: some View {
        let shape = NotchShape(topRadius: 3, bottomRadius: 9)
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.36, green: 0.52, blue: 0.86), Color(red: 0.86, green: 0.55, blue: 0.62)],
                           startPoint: .leading, endPoint: .trailing)
            Rectangle().fill(.white.opacity(0.5)).frame(height: 7)
            Group {
                if material == .glass, !NotchMaterial.isGlassAvailable {
                    shape.fill(.white.opacity(0.3))
                } else {
                    NotchSurface(isGlass: material == .glass, topRadius: 3, bottomRadius: 9, bandHeight: 7)
                }
            }
            .clipShape(shape)
            .overlay(alignment: .top) {
                // A tab and a card, so the material reads as the notch.
                HStack(spacing: 3) {
                    Capsule().fill(.white.opacity(0.85)).frame(width: 9, height: 3)
                    Capsule().fill(.white.opacity(0.3)).frame(width: 5, height: 3)
                }
                .padding(.top, 5)
            }
            .frame(width: 58, height: 26)
        }
        .frame(width: 86, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// The accent colors as a row of swatches, as in System Settings.
private struct AccentPicker: View {
    @Binding var selection: NotchAccent

    var body: some View {
        HStack(spacing: 10) {
            ForEach(NotchAccent.allCases) { accent in
                AccentSwatch(accent: accent, isSelected: selection == accent) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { selection = accent }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Accent color")
    }
}

private struct AccentSwatch: View {
    let accent: NotchAccent
    let isSelected: Bool
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(accent.color.gradient)
                .overlay(Circle().strokeBorder(.black.opacity(0.12)))
                .overlay {
                    if isSelected {
                        Circle().fill(.white).frame(width: 7, height: 7)
                            .shadow(color: .black.opacity(0.25), radius: 1)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: 22, height: 22)
                .padding(3)
                .overlay(Circle().strokeBorder(accent.color.opacity(isSelected ? 0.9 : hovering ? 0.35 : 0), lineWidth: 2))
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.9))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(accent.title)
        .accessibilityLabel(accent.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// The top of an external display with the virtual notch hanging from it, or the line it rests as, at half size.
private struct VirtualNotchSketch: View {
    let width: Double
    var style: VirtualNotchStyle = .notch

    var body: some View {
        let isLine = style == .line
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.36, green: 0.52, blue: 0.86), Color(red: 0.86, green: 0.55, blue: 0.62)],
                           startPoint: .leading, endPoint: .trailing)
                .opacity(0.85)
            Rectangle().fill(.white.opacity(0.5)).frame(height: 12)
            NotchShape(topRadius: isLine ? 0 : 3, bottomRadius: isLine ? 1 : 6)
                .fill(.black.opacity(isLine ? 0.4 : 1))
                .frame(width: width / 2 + (isLine ? 0 : 6), height: isLine ? 2 : 14)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: width)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: style)
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
    case micMuted, countdowns, downloads, focusMode
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
        case .micMuted: "Muted microphone"
        case .countdowns: "Timers"
        case .downloads: "Downloads"
        case .focusMode: "Focus"
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
        case .micMuted: "A red badge while the mic is muted"
        case .countdowns: "Named timers and the stopwatch from the Focus tab"
        case .downloads: "Progress as a file downloads, and a notice when it's done"
        case .focusMode: "Your Focus's symbol while one is on, and a notice when it changes"
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
        case .micMuted: "mic.slash.fill"
        case .countdowns: "hourglass"
        case .downloads: "arrow.down.circle.fill"
        case .focusMode: "moon.fill"
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
        case .micMuted: .red
        case .countdowns: TimerStore.tint
        case .downloads: DownloadMonitor.tint
        case .focusMode: .indigo
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
        case .micMuted: \.liveMicMuted
        case .countdowns: \.liveCountdowns
        case .downloads: \.liveDownloads
        case .focusMode: \.liveFocus
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
        case .micMuted: .idle
        case .countdowns: .countdown(Self.sampleCountdown)
        case .downloads: .download
        case .focusMode: .idle
        }
    }

    private static let sampleCountdown = Countdown(id: UUID(), name: "Tea", duration: 240, pausedRemaining: 221)

    /// A glyph at the end of the right ear, for the activities that only ever show as one.
    var sampleSecondary: CompactActivity? {
        switch self {
        case .micMuted: .micMuted
        case .focusMode: .focus(FocusMode(id: "sample", name: "Do Not Disturb", symbol: "moon.fill", tint: .indigo))
        default: nil
        }
    }
}

struct ActivitySettings: View {
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var focus = FocusMonitor.shared

    private let options = [
        SwitchOption(title: "Two at once", detail: "A second activity as a small glyph at the end of the right ear",
                     symbol: "circle.grid.2x1.right.filled", tint: Palette.lavender, setting: \.liveSecondary),
        SwitchOption(title: "On-air ring", detail: "A thin outline around the notch while a camera or the mic is in use",
                     symbol: "record.circle", tint: .green, setting: \.onAirRing),
        SwitchOption(title: "Mute shortcut", detail: "⌃⌥M mutes and unmutes the mic in every app",
                     symbol: "mic.fill", tint: .orange, setting: \.micShortcut),
        SwitchOption(title: "Downloads to the Tray", detail: "Put each finished download in the Tray",
                     symbol: "tray.and.arrow.down.fill", tint: .teal, setting: \.downloadsToTray),
    ]

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
            EqualizerAndKeysSettings()
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: settings.liveNotifications)
    }

    @ViewBuilder
    private var activities: some View {
        let onCount = LiveActivityKind.allCases.filter { settings[keyPath: $0.setting] }.count
        VStack(alignment: .leading, spacing: 26) {
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
            SettingsSection(title: "Options",
                            footer: "With two at once, the mute badge, a timer, a download, your Focus or the music you're playing keeps a small glyph while something else takes the notch. The ring is green for a camera and orange for the mic.") {
                SwitchGrid(options: options)
            }
        }
    }

    private func activityTile(_ kind: LiveActivityKind) -> some View {
        let needsMusic = kind == .trackPeek && !settings.liveMusic
        let needsDiskAccess = kind == .focusMode && settings.liveFocus && focus.access == .denied
        let detail = needsMusic ? "Needs Now playing" : needsDiskAccess ? "Needs Full Disk Access, under Permissions" : kind.detail
        return SwitchTile(title: kind.title, detail: detail,
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
        SwitchOption(title: "Control", detail: "Toggles, sliders and batteries", symbol: NotchTab.stats.symbol,
                     tint: Color(red: 0.36, green: 0.56, blue: 1.0), spokenTitle: "Control tab", setting: \.showStatsTab),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            SettingsSection(title: "Tabs", footer: "The Nook tab, with the player, is always there.") {
                SwitchGrid(options: tabs, columns: 3)
            }
            SettingsSection(title: "Stacked beside the player",
                            footer: "One shows at a time. The stack turns by itself to whichever matters now: the calendar "
                                + "shortly before an event, the weather before rain, the batteries when one runs low.") {
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
            SettingsSection(title: "Notes",
                            footer: "Each note is a Markdown file named after its first line. Keep them in iCloud Drive to have them on all your Macs. Leaving Dynotch's own folder takes your notes along.") {
                NotesFolderCard()
            }
            SettingsSection(title: "Weather",
                            footer: "Forecasts come from Open-Meteo. Rain alerts use its 15-minute forecast where there is one, and the hourly forecast elsewhere.") {
                WeatherSettings()
            }
            SettingsSection(title: "Pinned shortcuts", trailing: "\(settings.pinnedShortcuts.count) of 4",
                            footer: "Pin up to four. They show in the Shortcuts widget.") {
                ShortcutPins()
            }
        }
    }
}

/// Where notes are kept, and ways to move them.
private struct NotesFolderCard: View {
    @ObservedObject private var store = NotesStore.shared

    var body: some View {
        SettingsCard {
            HStack(spacing: 12) {
                SymbolBadge(symbol: store.isInICloud ? "icloud.fill" : "folder.fill", tint: store.isInICloud ? .blue : .yellow,
                            size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.isUsingDefaultFolder ? "Dynotch's folder" : FileManager.default.displayName(atPath: store.folder.path))
                        .font(.system(size: 13, weight: .medium))
                    Text(Self.describe(store.folder))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 12)
                Text(store.notes.filter(\.isOnDisk).count == 1 ? "1 note" : "\(store.notes.filter(\.isOnDisk).count) notes")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            CardDivider()
            HStack(spacing: 8) {
                CapsuleButton(title: "Choose Folder…", symbol: "folder") {
                    if let folder = FileActions.chooseFolder(prompt: "Keep Notes Here") { store.useFolder(folder) }
                }
                if let iCloud = store.iCloudFolder, !store.isInICloud {
                    CapsuleButton(title: "Use iCloud Drive", symbol: "icloud") { store.useFolder(iCloud) }
                }
                if !store.isUsingDefaultFolder {
                    CapsuleButton(title: "Use Dynotch's Folder", symbol: "arrow.uturn.backward") { store.useFolder(nil) }
                }
                Spacer(minLength: 0)
                CapsuleButton(title: "Show in Finder", symbol: "arrow.up.forward") { NSWorkspace.shared.open(store.folder) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
    }

    /// "iCloud Drive › Dynotch Notes", or the path with ~ for the home folder.
    private static func describe(_ folder: URL) -> String {
        let drive = "/Library/Mobile Documents/com~apple~CloudDocs"
        if let range = folder.path.range(of: drive) {
            let rest = folder.path[range.upperBound...].split(separator: "/").joined(separator: " › ")
            return rest.isEmpty ? "iCloud Drive" : "iCloud Drive › " + rest
        }
        return (folder.path as NSString).abbreviatingWithTildeInPath
    }
}

/// Where the Weather widget looks, which units it uses, and rain alerts.
private struct WeatherSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var weather = WeatherService.shared
    @ViewState private var query = ""
    @ViewState private var results: [WeatherService.Place] = []
    @ViewState private var isSearching = false
    @ViewState private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsCard {
                SwitchRow(title: "Use my location", detail: locationDetail, symbol: "location.fill", tint: .blue,
                          isOn: Binding(get: { settings.weatherUsesLocation }, set: { isOn in
                    settings.weatherUsesLocation = isOn
                    if isOn { weather.requestLocationAccess() }
                }))
                if !settings.weatherUsesLocation {
                    CardDivider()
                    cityRow
                    ForEach(results) { place in
                        CardDivider()
                        PlaceRow(place: place) {
                            weather.choose(place)
                            searchTask?.cancel()
                            query = ""
                            results = []
                        }
                    }
                    if !isSearching, results.isEmpty, query.trimmingCharacters(in: .whitespaces).count >= 2 {
                        CardDivider()
                        Text("No places found")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                }
            }
            unitsCard
            SettingsCard {
                SwitchRow(title: "Rain alerts", detail: "A heads-up in the closed notch when rain is about to start",
                          symbol: "cloud.rain.fill", tint: .cyan, isOn: $settings.rainAlerts)
            }
        }
        .onChange(of: query) { search() }
    }

    private var locationDetail: String {
        guard settings.weatherUsesLocation else { return "Instead of a city, use where this Mac is" }
        switch weather.locationAccess {
        case .notDetermined: return "Waiting for Location Services"
        case .denied, .restricted: return "Location Services is off for Dynotch. Allow it in System Settings."
        default: return weather.placeName.isEmpty ? "Finding where you are…" : "Now in \(weather.placeName)"
        }
    }

    private var cityRow: some View {
        HStack(spacing: 12) {
            SymbolBadge(symbol: "building.2.fill", tint: .indigo, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("City")
                    .font(.system(size: 13, weight: .medium))
                Text(settings.weatherPlace.isEmpty ? "None yet" : settings.weatherPlace)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search for a city", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                if isSearching {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .frame(width: 240, height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.wash))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var unitsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Temperature")
                .font(.system(size: 13, weight: .semibold))
                .padding(.leading, 2)
                .accessibilityHidden(true)
            HStack(spacing: 6) {
                ForEach(TemperatureUnits.allCases) { units in
                    ChoiceChip(title: title(for: units), symbol: symbol(for: units), isSelected: settings.weatherUnits == units) {
                        settings.weatherUnits = units
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Temperature")
    }

    private func title(for units: TemperatureUnits) -> String {
        switch units {
        case .system: WeatherService.systemUsesFahrenheit ? "Like the system (°F)" : "Like the system (°C)"
        case .celsius: "Celsius"
        case .fahrenheit: "Fahrenheit"
        }
    }

    private func symbol(for units: TemperatureUnits) -> String {
        switch units {
        case .system: "gearshape"
        case .celsius: "degreesign.celsius"
        case .fahrenheit: "degreesign.fahrenheit"
        }
    }

    /// Searches as you type, once you pause.
    private func search() {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let found = await WeatherService.search(text)
            guard !Task.isCancelled else { return }
            results = found
            isSearching = false
        }
    }
}

/// A city found by the weather search.
private struct PlaceRow: View {
    let place: WeatherService.Place
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(place.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    if !place.region.isEmpty {
                        Text(place.region)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                Text("Use")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Palette.wash.opacity(hovering ? 1 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(place.region.isEmpty ? place.name : "\(place.name), \(place.region)")
        .accessibilityHint("Shows the weather for this place")
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
    @ObservedObject private var settings = AppSettings.shared

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
            SettingsSection(title: "Screenshots",
                            footer: "Dynotch watches the folder the Screenshot app saves to: \(ScreenshotWatcher.folderNames).") {
                SettingsCard {
                    SwitchRow(title: "Add screenshots to the tray", detail: "New screenshots and screen recordings show up here",
                              symbol: "camera.viewfinder", tint: .orange, isOn: $settings.screenshotsToTray)
                }
            }
            SettingsSection(title: "In the tray", footer: "Click an item and press Space to preview it, as in Finder. The arrow keys move between items.") {
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
        SwitchOption(title: "Sound", detail: "Play a sound when a phase or a named timer ends", symbol: "bell.fill",
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
    @ObservedObject private var focus = FocusMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(spacing: 14) {
                DynotchLogo(size: 92)
                    .shadow(color: Palette.lavender.opacity(0.45), radius: 18, y: 6)
                VStack(spacing: 3) {
                    Text("Dynotch")
                        .font(.system(size: 26, weight: .bold))
                    Text("Version \(UpdateChecker.currentVersion)")
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
                CapsuleButton(title: "Welcome Tour", symbol: "sparkles") { WelcomeWindowController.shared.show() }
                    .padding(.top, 4)
            }
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity)
            .background(CardBackground())

            SettingsSection(title: "Updates") {
                UpdateSettings()
            }

            SettingsSection(title: "Keyboard") {
                SettingsCard {
                    ShortcutRow(keys: ["⌃", "⌥", "N"], spokenKeys: "Control Option N", action: settings.globalShortcut
                        ? "Open or close the notch" : "Open or close the notch (turned off in General)")
                    CardDivider()
                    ShortcutRow(keys: ["⌃", "⌥", "M"], spokenKeys: "Control Option M", action: settings.micShortcut
                        ? "Mute or unmute the microphone" : "Mute or unmute the microphone (turned off in Live Activities)")
                    CardDivider()
                    ShortcutRow(keys: ["⌃", "⌥", "K"], spokenKeys: "Control Option K", action: settings.commandShortcut
                        ? "Open the command field" : "Open the command field (turned off in General)")
                    CardDivider()
                    ShortcutRow(keys: ["⌘", "1 – 8"], spokenKeys: "Command 1 to 8", action: "Jump to a page of these settings")
                    CardDivider()
                    ShortcutRow(keys: ["↑", "↓"], spokenKeys: "Up or down arrow",
                                action: "Move through the pages, once the sidebar is selected")
                }
            }

            SettingsSection(title: "Diagnostics",
                            footer: "For when the notch shows the wrong Focus. The report keeps the shape of the Focus settings, their identifiers and times; names and places are left out, so it can be shared.") {
                HStack(spacing: 12) {
                    SymbolBadge(symbol: "moon.fill", tint: .indigo, size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Focus report")
                            .font(.system(size: 13, weight: .medium))
                        Text(focus.access == .denied ? "Needs Full Disk Access, under Permissions"
                             : "What the Focus settings hold, and which Focus Dynotch makes of them")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 12)
                    CapsuleButton(title: "Save…", symbol: "square.and.arrow.down") { FocusMonitor.shared.saveReport() }
                        .accessibilityLabel("Save a Focus report")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CardBackground())
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
