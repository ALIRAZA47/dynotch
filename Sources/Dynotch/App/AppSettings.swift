import SwiftUI

/// Where Dynotch keeps what it saves between launches: its own defaults, or a scratch domain
/// with sample values while `--snapshot` renders, so a snapshot run never reads or writes the real ones.
extension UserDefaults {
    nonisolated(unsafe) static var dynotch: UserDefaults = .standard
}

enum DisplayMode: String, CaseIterable, Identifiable {
    case notched, main, all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notched: "Built-in display"
        case .main: "Main display"
        case .all: "All displays"
        }
    }
}

/// How the closed notch looks on a display without a camera notch.
enum VirtualNotchStyle: String, CaseIterable, Identifiable {
    /// A black notch hangs from the menu bar, as on a MacBook.
    case notch
    /// A faint line along the top edge, so nothing is covered. It grows into the notch while
    /// something's on, under the pointer, and when it opens.
    case line

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notch: "Notch"
        case .line: "Line"
        }
    }

    var detail: String {
        switch self {
        case .notch: "Hangs from the menu bar"
        case .line: "A faint line at the top edge"
        }
    }
}

enum NotchTab: String, CaseIterable, Identifiable {
    case home, tray, focus, stats

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Nook"
        case .tray: "Tray"
        case .focus: "Focus"
        case .stats: "Stats"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .tray: "tray.full.fill"
        case .focus: "timer"
        case .stats: "gauge.with.dots.needle.67percent"
        }
    }
}

/// Widgets that can sit next to the media player on the Nook tab.
enum HomeWidget: String, CaseIterable, Identifiable {
    case calendar, mirror, shortcuts, timer, devices, toggles, notes, weather, none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calendar: "Calendar"
        case .mirror: "Mirror"
        case .shortcuts: "Shortcuts"
        case .timer: "Focus timer"
        case .devices: "Batteries"
        case .toggles: "Quick toggles"
        case .notes: "Notes"
        case .weather: "Weather"
        case .none: "Nothing"
        }
    }

    var symbol: String {
        switch self {
        case .calendar: "calendar"
        case .mirror: "person.crop.square"
        case .shortcuts: "square.stack.3d.up.fill"
        case .timer: "timer"
        case .devices: "battery.75percent"
        case .toggles: "switch.2"
        case .notes: "note.text"
        case .weather: "cloud.sun.fill"
        case .none: "minus.circle"
        }
    }
}

/// How the Weather widget shows temperatures.
enum TemperatureUnits: String, CaseIterable, Identifiable {
    case system, celsius, fahrenheit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .celsius: "Celsius"
        case .fahrenheit: "Fahrenheit"
        }
    }
}

enum PlayerChoice: String, CaseIterable, Identifiable {
    case music, spotify

    var id: String { rawValue }
    var title: String { self == .music ? "Apple Music" : "Spotify" }
}

/// User preferences, persisted in UserDefaults as they change.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // MARK: General

    @Published var openOnHover: Bool = AppSettings.value("openOnHover", true) {
        didSet { save("openOnHover", openOnHover) }
    }
    @Published var hoverDelay: Double = AppSettings.value("hoverDelay", 0.15) {
        didSet { save("hoverDelay", hoverDelay) }
    }
    @Published var swipeGestures: Bool = AppSettings.value("swipeGestures", true) {
        didSet { save("swipeGestures", swipeGestures) }
    }
    @Published var haptics: Bool = AppSettings.value("haptics", true) {
        didSet { save("haptics", haptics) }
    }
    @Published var displayMode: DisplayMode = AppSettings.value("displayMode", DisplayMode.notched) {
        didSet { save("displayMode", displayMode.rawValue) }
    }
    @Published var showMenuBarIcon: Bool = AppSettings.value("showMenuBarIcon", true) {
        didSet { save("showMenuBarIcon", showMenuBarIcon) }
    }
    @Published var globalShortcut: Bool = AppSettings.value("globalShortcut", true) {
        didSet { save("globalShortcut", globalShortcut) }
    }
    @Published var hasLaunchedBefore: Bool = AppSettings.value("hasLaunchedBefore", false) {
        didSet { save("hasLaunchedBefore", hasLaunchedBefore) }
    }

    // MARK: Appearance

    @Published var openWidth: Double = AppSettings.value("openWidth", 660) {
        didSet { save("openWidth", openWidth) }
    }
    @Published var openHeight: Double = AppSettings.value("openHeight", 210) {
        didSet { save("openHeight", openHeight) }
    }
    @Published var virtualNotchWidth: Double = AppSettings.value("virtualNotchWidth", 190) {
        didSet { save("virtualNotchWidth", virtualNotchWidth) }
    }
    /// On a display without a camera notch: a black notch, or a line that only becomes one when needed.
    @Published var virtualNotchStyle: VirtualNotchStyle = AppSettings.value("virtualNotchStyle", VirtualNotchStyle.notch) {
        didSet { save("virtualNotchStyle", virtualNotchStyle.rawValue) }
    }
    @Published var artworkTint: Bool = AppSettings.value("artworkTint", true) {
        didSet { save("artworkTint", artworkTint) }
    }
    @Published var showOpenShadow: Bool = AppSettings.value("showOpenShadow", true) {
        didSet { save("showOpenShadow", showOpenShadow) }
    }

    // MARK: Theme

    /// Black or glass. Only the open notch changes: the closed one stays black, like the camera housing.
    @Published var notchMaterial: NotchMaterial = AppSettings.value("notchMaterial", NotchMaterial.black) {
        didSet { save("notchMaterial", notchMaterial.rawValue) }
    }
    @Published var notchAccent: NotchAccent = AppSettings.value("notchAccent", NotchAccent.lavender) {
        didSet { save("notchAccent", notchAccent.rawValue) }
    }
    /// Where the open notch meets the top of the screen, in points.
    @Published var notchTopRadius: Double = AppSettings.value("notchTopRadius", 12.0) {
        didSet { save("notchTopRadius", notchTopRadius) }
    }
    /// The open notch's bottom corners, in points. The cards inside follow them.
    @Published var notchBottomRadius: Double = AppSettings.value("notchBottomRadius", 30.0) {
        didSet { save("notchBottomRadius", notchBottomRadius) }
    }

    /// The open notch's look, from the four settings above.
    var theme: NotchTheme {
        NotchTheme(material: notchMaterial, accent: notchAccent, topRadius: notchTopRadius, bottomRadius: notchBottomRadius)
    }

    // MARK: Equalizer and keys

    @Published var replaceSystemHUD: Bool = AppSettings.value("replaceSystemHUD", false) {
        didSet { save("replaceSystemHUD", replaceSystemHUD) }
    }
    @Published var liveEqualizer: Bool = AppSettings.value("liveEqualizer", false) {
        didSet { save("liveEqualizer", liveEqualizer) }
    }

    // MARK: Live activities

    @Published var liveMusic: Bool = AppSettings.value("liveMusic", true) {
        didSet { save("liveMusic", liveMusic) }
    }
    @Published var trackPeek: Bool = AppSettings.value("trackPeek", true) {
        didSet { save("trackPeek", trackPeek) }
    }
    @Published var liveTimer: Bool = AppSettings.value("liveTimer", true) {
        didSet { save("liveTimer", liveTimer) }
    }
    @Published var liveCharging: Bool = AppSettings.value("liveCharging", true) {
        didSet { save("liveCharging", liveCharging) }
    }
    @Published var lowBatteryAlerts: Bool = AppSettings.value("lowBatteryAlerts", true) {
        didSet { save("lowBatteryAlerts", lowBatteryAlerts) }
    }
    @Published var liveHUD: Bool = AppSettings.value("liveHUD", true) {
        didSet { save("liveHUD", liveHUD) }
    }
    @Published var liveEvents: Bool = AppSettings.value("liveEvents", true) {
        didSet { save("liveEvents", liveEvents) }
    }
    @Published var liveDevices: Bool = AppSettings.value("liveDevices", true) {
        didSet { save("liveDevices", liveDevices) }
    }

    // MARK: Live activities: two at once, microphone, timers, downloads, Focus

    /// A second activity as a glyph in the right ear.
    @Published var liveSecondary: Bool = AppSettings.value("liveSecondary", true) {
        didSet { save("liveSecondary", liveSecondary) }
    }
    /// A red badge while the microphone is muted.
    @Published var liveMicMuted: Bool = AppSettings.value("liveMicMuted", true) {
        didSet { save("liveMicMuted", liveMicMuted) }
    }
    /// ⌃⌥M mutes and unmutes the microphone.
    @Published var micShortcut: Bool = AppSettings.value("micShortcut", true) {
        didSet { save("micShortcut", micShortcut) }
    }
    /// An outline around the closed notch while a camera or the microphone is in use.
    @Published var onAirRing: Bool = AppSettings.value("onAirRing", true) {
        didSet { save("onAirRing", onAirRing) }
    }
    /// Named timers and the stopwatch from the Focus tab.
    @Published var liveCountdowns: Bool = AppSettings.value("liveCountdowns", true) {
        didSet { save("liveCountdowns", liveCountdowns) }
    }
    /// Progress while files arrive in ~/Downloads, and a notice when one is done.
    @Published var liveDownloads: Bool = AppSettings.value("liveDownloads", true) {
        didSet { save("liveDownloads", liveDownloads) }
    }
    /// Finished downloads go into the Tray.
    @Published var downloadsToTray: Bool = AppSettings.value("downloadsToTray", false) {
        didSet { save("downloadsToTray", downloadsToTray) }
    }
    /// The Focus that's on, by its symbol, and a notice when it changes.
    @Published var liveFocus: Bool = AppSettings.value("liveFocus", true) {
        didSet { save("liveFocus", liveFocus) }
    }

    // MARK: Nook

    @Published var homeWidgetA: HomeWidget = AppSettings.value("homeWidgetA", HomeWidget.calendar) {
        didSet { save("homeWidgetA", homeWidgetA.rawValue) }
    }
    @Published var homeWidgetB: HomeWidget = AppSettings.value("homeWidgetB", HomeWidget.mirror) {
        didSet { save("homeWidgetB", homeWidgetB.rawValue) }
    }
    @Published var showTrayTab: Bool = AppSettings.value("showTrayTab", true) {
        didSet { save("showTrayTab", showTrayTab) }
    }
    @Published var showFocusTab: Bool = AppSettings.value("showFocusTab", true) {
        didSet { save("showFocusTab", showFocusTab) }
    }
    @Published var showStatsTab: Bool = AppSettings.value("showStatsTab", true) {
        didSet { save("showStatsTab", showStatsTab) }
    }
    @Published var preferredPlayer: PlayerChoice = AppSettings.value("preferredPlayer", PlayerChoice.music) {
        didSet { save("preferredPlayer", preferredPlayer.rawValue) }
    }
    @Published var pinnedShortcuts: [String] = AppSettings.value("pinnedShortcuts", [String]()) {
        didSet { save("pinnedShortcuts", pinnedShortcuts) }
    }
    @Published var showAllDayEvents: Bool = AppSettings.value("showAllDayEvents", true) {
        didSet { save("showAllDayEvents", showAllDayEvents) }
    }
    /// Where notes are kept as Markdown files. Empty for Dynotch's own folder.
    @Published var notesFolderPath: String = AppSettings.value("notesFolderPath", "") {
        didSet { save("notesFolderPath", notesFolderPath) }
    }

    // MARK: Weather

    /// The city picked in Settings, as shown: "Lisbon, Portugal". Empty until one is picked.
    @Published var weatherPlace: String = AppSettings.value("weatherPlace", "") {
        didSet { save("weatherPlace", weatherPlace) }
    }
    @Published var weatherLatitude: Double = AppSettings.value("weatherLatitude", 0.0) {
        didSet { save("weatherLatitude", weatherLatitude) }
    }
    @Published var weatherLongitude: Double = AppSettings.value("weatherLongitude", 0.0) {
        didSet { save("weatherLongitude", weatherLongitude) }
    }
    /// Use where the Mac is, from Location Services, instead of the city.
    @Published var weatherUsesLocation: Bool = AppSettings.value("weatherUsesLocation", false) {
        didSet { save("weatherUsesLocation", weatherUsesLocation) }
    }
    @Published var weatherUnits: TemperatureUnits = AppSettings.value("weatherUnits", TemperatureUnits.system) {
        didSet { save("weatherUnits", weatherUnits.rawValue) }
    }
    @Published var rainAlerts: Bool = AppSettings.value("rainAlerts", true) {
        didSet { save("rainAlerts", rainAlerts) }
    }

    // MARK: Tray

    @Published var trayCopiesFiles: Bool = AppSettings.value("trayCopiesFiles", false) {
        didSet { save("trayCopiesFiles", trayCopiesFiles) }
    }
    @Published var trayOpensOnDrag: Bool = AppSettings.value("trayOpensOnDrag", true) {
        didSet { save("trayOpensOnDrag", trayOpensOnDrag) }
    }
    @Published var screenshotsToTray: Bool = AppSettings.value("screenshotsToTray", true) {
        didSet { save("screenshotsToTray", screenshotsToTray) }
    }

    // MARK: Focus timer

    @Published var focusMinutes: Int = AppSettings.value("focusMinutes", 25) {
        didSet { save("focusMinutes", focusMinutes) }
    }
    @Published var shortBreakMinutes: Int = AppSettings.value("shortBreakMinutes", 5) {
        didSet { save("shortBreakMinutes", shortBreakMinutes) }
    }
    @Published var longBreakMinutes: Int = AppSettings.value("longBreakMinutes", 15) {
        didSet { save("longBreakMinutes", longBreakMinutes) }
    }
    @Published var sessionsPerRound: Int = AppSettings.value("sessionsPerRound", 4) {
        didSet { save("sessionsPerRound", sessionsPerRound) }
    }
    @Published var autoStartNextPhase: Bool = AppSettings.value("autoStartNextPhase", false) {
        didSet { save("autoStartNextPhase", autoStartNextPhase) }
    }
    @Published var timerSound: Bool = AppSettings.value("timerSound", true) {
        didSet { save("timerSound", timerSound) }
    }

    // MARK: Updates

    /// Ask GitHub for the newest release once a day, and say in the notch when there is one.
    @Published var checksForUpdates: Bool = AppSettings.value("checksForUpdates", true) {
        didSet { save("checksForUpdates", checksForUpdates) }
    }

    // MARK: Notification peeks

    @Published var liveNotifications: Bool = AppSettings.value("liveNotifications", true) {
        didSet { save("liveNotifications", liveNotifications) }
    }
    /// Peeks show only the app and the sender.
    @Published var notificationHideText: Bool = AppSettings.value("notificationHideText", false) {
        didSet { save("notificationHideText", notificationHideText) }
    }
    /// Apps from `NotificationPeek.sources` that don't peek, by their `id`.
    @Published var notificationMutedApps: [String] = AppSettings.value("notificationMutedApps", [String]()) {
        didSet { save("notificationMutedApps", notificationMutedApps) }
    }
    /// Whether apps that aren't in `NotificationPeek.sources` peek.
    @Published var notificationOtherApps: Bool = AppSettings.value("notificationOtherApps", true) {
        didSet { save("notificationOtherApps", notificationOtherApps) }
    }

    var enabledTabs: [NotchTab] {
        NotchTab.allCases.filter { tab in
            switch tab {
            case .home: true
            case .tray: showTrayTab
            case .focus: showFocusTab
            case .stats: showStatsTab
            }
        }
    }

    var homeWidgets: [HomeWidget] {
        [homeWidgetA, homeWidgetB].filter { $0 != .none }
    }

    private init() {}

    private func save(_ key: String, _ value: Any) {
        UserDefaults.dynotch.set(value, forKey: key)
    }

    nonisolated private static func value<T>(_ key: String, _ fallback: T) -> T {
        UserDefaults.dynotch.object(forKey: key) as? T ?? fallback
    }

    nonisolated private static func value<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
        UserDefaults.dynotch.string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
    }
}
