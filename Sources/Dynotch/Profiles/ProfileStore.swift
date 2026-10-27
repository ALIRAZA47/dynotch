import AppKit
import Combine
import SwiftUI

/// A saved setup of the notch, like Work, Home or Presenting: its tabs, widgets, live activities,
/// how it opens, where it shows up and how big it is. A profile can switch on by itself when a
/// Focus turns on or an external display connects.
struct Profile: Identifiable, Codable, Equatable {
    /// What switches a profile on by itself.
    enum Rule: Codable, Hashable {
        /// A Focus turning on: the one with this identifier, or any Focus when it's nil.
        case focus(id: String?, name: String)
        /// A display other than the built-in one connecting.
        case externalDisplay
    }

    let id: UUID
    var name: String
    var rule: Rule?
    /// Settings by their `AppSettings` name.
    var values: [String: ProfileValue]

    var isFocusRule: Bool {
        if case .focus = rule { return true }
        return false
    }

    /// A symbol that fits the name: a briefcase for Work, a house for Home, otherwise its first letter.
    var symbol: String {
        let words = name.lowercased().split { !$0.isLetter }
        for (prefixes, symbol) in Self.symbols where words.contains(where: { word in prefixes.contains { word.hasPrefix($0) } }) {
            return symbol
        }
        if let letter = name.lowercased().first(where: { $0.isLetter && $0.isASCII }) { return "\(letter).circle.fill" }
        return "square.stack.3d.up.fill"
    }

    /// One of a few colors, always the same for a profile.
    var tint: Color {
        let hash = id.uuidString.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Self.tints[hash % Self.tints.count]
    }

    private static let symbols: [(prefixes: [String], symbol: String)] = [
        (["work", "office", "job"], "briefcase.fill"),
        (["home", "house"], "house.fill"),
        (["present", "demo", "talk", "keynote", "slide", "screen"], "play.rectangle.fill"),
        (["meeting", "call"], "video.fill"),
        (["desk", "display", "monitor", "external"], "display"),
        (["study", "school", "class", "read", "deep"], "book.fill"),
        (["night", "sleep", "evening", "bed"], "moon.fill"),
        (["travel", "trip", "flight", "away", "road"], "airplane"),
        (["game", "gaming"], "gamecontroller.fill"),
        (["music", "studio", "listen"], "music.note"),
        (["coffee", "cafe", "café"], "cup.and.saucer.fill"),
        (["minimal", "quiet", "calm", "simple", "clean"], "leaf.fill"),
    ]

    private static let tints: [Color] = [Palette.lavender, .teal, .orange, Palette.magenta, .blue, .green, .indigo, .pink]
}

/// A setting's value as a profile keeps it. Stored as the plain JSON value.
enum ProfileValue: Codable, Equatable {
    case bool(Bool)
    case number(Double)
    case text(String)
    case list([String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .text(value)
        } else {
            self = .list(try container.decode([String].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .text(let value): try container.encode(value)
        case .list(let value): try container.encode(value)
        }
    }
}

/// A setting that belongs to profiles: how to read it from `AppSettings` and put it back.
struct ProfileSetting {
    let key: String
    let read: @MainActor (AppSettings) -> ProfileValue
    let write: @MainActor (AppSettings, ProfileValue) -> Void

    static func bool(_ key: String, _ path: ReferenceWritableKeyPath<AppSettings, Bool>) -> ProfileSetting {
        ProfileSetting(key: key, read: { .bool($0[keyPath: path]) }) { settings, value in
            if case .bool(let new) = value, settings[keyPath: path] != new { settings[keyPath: path] = new }
        }
    }

    static func number(_ key: String, _ path: ReferenceWritableKeyPath<AppSettings, Double>) -> ProfileSetting {
        ProfileSetting(key: key, read: { .number($0[keyPath: path]) }) { settings, value in
            if case .number(let new) = value, settings[keyPath: path] != new { settings[keyPath: path] = new }
        }
    }

    static func choice<Choice: RawRepresentable & Equatable>(_ key: String,
                                                              _ path: ReferenceWritableKeyPath<AppSettings, Choice>) -> ProfileSetting
        where Choice.RawValue == String {
        ProfileSetting(key: key, read: { .text($0[keyPath: path].rawValue) }) { settings, value in
            if case .text(let raw) = value, let new = Choice(rawValue: raw), settings[keyPath: path] != new {
                settings[keyPath: path] = new
            }
        }
    }

    static func list(_ key: String, _ path: ReferenceWritableKeyPath<AppSettings, [String]>) -> ProfileSetting {
        ProfileSetting(key: key, read: { .list($0[keyPath: path]) }) { settings, value in
            if case .list(let new) = value, settings[keyPath: path] != new { settings[keyPath: path] = new }
        }
    }

    /// Everything a profile switches: what the notch shows and how it opens. App-wide settings stay
    /// out (launch at login, the menu bar icon, keyboard shortcuts), as do settings that ask for a
    /// permission when turned on (Replace system HUD, Live equalizer), where things are kept, and the
    /// weather's place.
    @MainActor static let all: [ProfileSetting] = [
        // Opening the notch, and where it shows up
        .bool("openOnHover", \.openOnHover),
        .number("hoverDelay", \.hoverDelay),
        .bool("swipeGestures", \.swipeGestures),
        .bool("haptics", \.haptics),
        .bool("trayOpensOnDrag", \.trayOpensOnDrag),
        .choice("displayMode", \.displayMode),
        // Size and finish
        .number("openWidth", \.openWidth),
        .number("openHeight", \.openHeight),
        .number("virtualNotchWidth", \.virtualNotchWidth),
        .choice("virtualNotchStyle", \.virtualNotchStyle),
        .bool("artworkTint", \.artworkTint),
        .bool("showOpenShadow", \.showOpenShadow),
        .choice("notchMaterial", \.notchMaterial),
        .choice("notchAccent", \.notchAccent),
        .number("notchTopRadius", \.notchTopRadius),
        .number("notchBottomRadius", \.notchBottomRadius),
        // Tabs and widgets
        .bool("showTrayTab", \.showTrayTab),
        .bool("showFocusTab", \.showFocusTab),
        .bool("showStatsTab", \.showStatsTab),
        .choice("homeWidgetA", \.homeWidgetA),
        .choice("homeWidgetB", \.homeWidgetB),
        .list("pinnedShortcuts", \.pinnedShortcuts),
        // Live activities
        .bool("liveMusic", \.liveMusic),
        .bool("trackPeek", \.trackPeek),
        .bool("liveTimer", \.liveTimer),
        .bool("liveCharging", \.liveCharging),
        .bool("lowBatteryAlerts", \.lowBatteryAlerts),
        .bool("liveHUD", \.liveHUD),
        .bool("liveEvents", \.liveEvents),
        .bool("liveDevices", \.liveDevices),
        .bool("liveSecondary", \.liveSecondary),
        .bool("liveMicMuted", \.liveMicMuted),
        .bool("onAirRing", \.onAirRing),
        .bool("liveCountdowns", \.liveCountdowns),
        .bool("liveDownloads", \.liveDownloads),
        .bool("liveFocus", \.liveFocus),
        .bool("rainAlerts", \.rainAlerts),
        .bool("liveNotifications", \.liveNotifications),
        .bool("notificationHideText", \.notificationHideText),
        .list("notificationMutedApps", \.notificationMutedApps),
        .bool("notificationOtherApps", \.notificationOtherApps),
    ]
}

/// Saved profiles, the one that's on, and the rules that switch them.
///
/// The profile that's on follows your changes: change a widget while Work is on and Work keeps it.
/// A rule switches its profile on when its Focus turns on or an external display connects, and when
/// that ends, puts things back as they were, unless you switched profiles by hand in between.
@MainActor
final class ProfileStore: ObservableObject {
    static let shared = ProfileStore()

    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var activeID: UUID?
    /// Settings asked to show the Profiles section, from the menu bar menu.
    @Published var revealRequested = false

    /// How things were before a rule switched a profile on.
    private struct Restore: Codable {
        var profileID: UUID?
        var values: [String: ProfileValue]
    }

    private var restore: Restore?
    /// The profile the rules picked the last time they changed their mind.
    private var ruleTarget: UUID?
    private var isStarted = false
    private var cancellables = Set<AnyCancellable>()

    private enum Key {
        static let profiles = "profiles"
        static let active = "activeProfile"
        static let restore = "profileRestore"
        static let ruleTarget = "profileRuleTarget"
    }

    private init() {}

    var active: Profile? { profiles.first { $0.id == activeID } }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        load()
        updateFocusNeed()
        // Changes go into the profile that's on.
        AppSettings.shared.objectWillChange
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.captureIntoActive() }
            .store(in: &cancellables)
        // These publish before the value changes, so look on the next turn.
        Publishers.Merge(FocusMonitor.shared.$mode.map { _ in () }, FocusMonitor.shared.$access.map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.evaluateRules() }
            .store(in: &cancellables)
        // A display arriving sends several of these.
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.evaluateRules() }
            .store(in: &cancellables)
        // Monitors can drop off while the displays sleep. Judge again once someone's back and
        // they've had a few seconds to return.
        EnergyCoordinator.shared.$conditions
            .map(\.isQuiet)
            .removeDuplicates()
            .filter { !$0 }
            .debounce(for: .seconds(5), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.evaluateRules() }
            .store(in: &cancellables)
        evaluateRules()
    }

    // MARK: Switching

    /// Switches a profile on by hand. Rules leave it alone until their Focus or display changes again.
    func switchTo(_ profile: Profile) {
        guard let index = index(of: profile) else { return }
        restore = nil
        apply(profiles[index])
        persistState()
    }

    /// For dynotch://profile?name=Work. Says in the notch what happened.
    @discardableResult
    func switchTo(named name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let profile = profile(named: name) else {
            LiveActivityCenter.shared.post(LiveNotice(key: "profile", symbol: "questionmark.circle.fill", tint: .orange,
                                                      text: "", detail: "No profile called “\(name)”"), for: 3)
            return false
        }
        switchTo(profile)
        announce(profile)
        return true
    }

    func profile(named name: String) -> Profile? {
        profiles.first { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    // MARK: Editing

    /// Saves the setup as it is now under a new name, and switches that profile on.
    @discardableResult
    func saveCurrent(as name: String) -> Profile? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, profile(named: name) == nil else { return nil }
        captureIntoActive()
        let profile = Profile(id: UUID(), name: name, values: currentValues())
        profiles.append(profile)
        activeID = profile.id
        restore = nil
        persistProfiles()
        persistState()
        return profile
    }

    func rename(_ profile: Profile, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = index(of: profile) else { return }
        if let other = self.profile(named: name), other.id != profile.id { return }
        profiles[index].name = name
        persistProfiles()
    }

    func setRule(_ rule: Profile.Rule?, for profile: Profile) {
        guard let index = index(of: profile), profiles[index].rule != rule else { return }
        profiles[index].rule = rule
        persistProfiles()
        updateFocusNeed()
        evaluateRules(afterEditing: true)
    }

    func delete(_ profile: Profile) {
        guard let index = index(of: profile) else { return }
        profiles.remove(at: index)
        if activeID == profile.id { activeID = nil }
        if restore?.profileID == profile.id { restore?.profileID = nil }
        persistProfiles()
        persistState()
        updateFocusNeed()
        evaluateRules(afterEditing: true)
    }

    /// True when another profile already has this name.
    func isNameTaken(_ name: String, by other: Profile? = nil) -> Bool {
        guard let match = profile(named: name.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return match.id != other?.id
    }

    // MARK: Rules

    /// Picks the profile the rules want and switches to it when that changes. A rule for a named Focus
    /// beats one for any Focus, and Focus rules beat the external display. `afterEditing` means a rule
    /// was changed or a profile deleted: then nothing is put back, the profile that's on just stays.
    private func evaluateRules(afterEditing: Bool = false) {
        // Nobody would see it, and displays come and go as they sleep.
        guard isStarted, !EnergyCoordinator.shared.isQuiet else { return }
        let focus = FocusMonitor.shared
        // Until the Focus database has been read, Focus rules can't be judged either way.
        if profiles.contains(where: \.isFocusRule), focus.access == .unknown { return }
        let target = ruleChoice(focus: focus.access == .granted ? focus.mode : nil, externalDisplay: Self.hasExternalDisplay)
        guard target != ruleTarget else { return }
        let leaving = profiles.first { $0.id == ruleTarget }
        ruleTarget = target
        if let profile = profiles.first(where: { $0.id == target }) {
            if restore == nil { restore = Restore(profileID: activeID, values: currentValues()) }
            apply(profile)
            // A Focus says so itself when it turns on; a display doesn't.
            if profile.rule == .externalDisplay { announce(profile) }
        } else if let previous = restore {
            restore = nil
            if !afterEditing {
                captureIntoActive()
                let back = profiles.first { $0.id == previous.profileID }
                activeID = back?.id
                applyValues(previous.values)
                if leaving?.rule == .externalDisplay, let back { announce(back) }
            }
        }
        persistState()
    }

    private func ruleChoice(focus: FocusMode?, externalDisplay: Bool) -> UUID? {
        if let focus {
            var anyFocus: Profile?
            for profile in profiles {
                guard case .focus(let id, _) = profile.rule else { continue }
                if id == focus.id { return profile.id }
                if id == nil, anyFocus == nil { anyFocus = profile }
            }
            if let anyFocus { return anyFocus.id }
        }
        if externalDisplay, let profile = profiles.first(where: { $0.rule == .externalDisplay }) { return profile.id }
        return nil
    }

    /// A display that isn't the Mac's own screen: a monitor, a TV, Sidecar.
    static var hasExternalDisplay: Bool {
        NSScreen.screens.contains { CGDisplayIsBuiltin($0.displayID) == 0 }
    }

    /// Focus is only read while something needs it; a profile with a Focus rule does.
    private func updateFocusNeed() {
        let needed = profiles.contains(where: \.isFocusRule)
        if FocusMonitor.shared.isNeededByProfiles != needed { FocusMonitor.shared.isNeededByProfiles = needed }
    }

    // MARK: Applying

    private func apply(_ profile: Profile) {
        captureIntoActive()
        activeID = profile.id
        applyValues(profile.values)
    }

    private func applyValues(_ values: [String: ProfileValue]) {
        let settings = AppSettings.shared
        for setting in ProfileSetting.all {
            if let value = values[setting.key] { setting.write(settings, value) }
        }
    }

    private func currentValues() -> [String: ProfileValue] {
        let settings = AppSettings.shared
        return Dictionary(uniqueKeysWithValues: ProfileSetting.all.map { ($0.key, $0.read(settings)) })
    }

    /// Keeps the profile that's on in step with the settings.
    private func captureIntoActive() {
        guard isStarted, let index = profiles.firstIndex(where: { $0.id == activeID }) else { return }
        let values = currentValues()
        guard profiles[index].values != values else { return }
        profiles[index].values = values
        persistProfiles()
    }

    /// A word in the notch when a profile switches on from outside Settings and the menu.
    private func announce(_ profile: Profile) {
        let short = profile.name.count <= 14
        LiveActivityCenter.shared.post(LiveNotice(key: "profile", symbol: profile.symbol, tint: profile.tint,
                                                  text: short ? profile.name : "", detail: short ? nil : profile.name), for: 2.6)
    }

    private func index(of profile: Profile) -> Int? {
        profiles.firstIndex { $0.id == profile.id }
    }

    // MARK: Storage

    private func load() {
        let defaults = UserDefaults.dynotch
        let decoder = JSONDecoder()
        profiles = defaults.data(forKey: Key.profiles).flatMap { try? decoder.decode([Profile].self, from: $0) } ?? []
        activeID = defaults.string(forKey: Key.active).flatMap(UUID.init(uuidString:))
        if !profiles.contains(where: { $0.id == activeID }) { activeID = nil }
        restore = defaults.data(forKey: Key.restore).flatMap { try? decoder.decode(Restore.self, from: $0) }
        ruleTarget = defaults.string(forKey: Key.ruleTarget).flatMap(UUID.init(uuidString:))
    }

    private func persistProfiles() {
        guard isStarted, let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.dynotch.set(data, forKey: Key.profiles)
    }

    private func persistState() {
        guard isStarted else { return }
        let defaults = UserDefaults.dynotch
        defaults.set(activeID?.uuidString, forKey: Key.active)
        defaults.set(restore.flatMap { try? JSONEncoder().encode($0) }, forKey: Key.restore)
        defaults.set(ruleTarget?.uuidString, forKey: Key.ruleTarget)
    }

    // MARK: Snapshots

    /// Sample profiles for snapshots. Kept in memory: nothing is saved.
    func loadSample(_ samples: [Profile], active: Int?) {
        profiles = samples
        activeID = active.map { samples[$0].id }
    }
}
