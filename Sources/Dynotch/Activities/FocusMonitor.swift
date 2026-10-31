import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// A Focus, as the closed notch shows it.
struct FocusMode: Equatable {
    var id: String
    var name: String
    var symbol: String
    var tint: Color
}

/// Which Focus is on. Apple's public API only says whether one is, so this reads the Focus
/// database in ~/Library/DoNotDisturb/DB: `Assertions.json` holds a Focus turned on by hand,
/// `ModeConfigurations.json` each Focus's name, symbol, color and schedule. Reading it needs
/// Full Disk Access; without it, nothing shows.
@MainActor
final class FocusMonitor: ObservableObject {
    static let shared = FocusMonitor()

    enum Access: Equatable {
        case unknown, granted, denied
    }

    @Published private(set) var mode: FocusMode?
    @Published private(set) var access: Access = .unknown
    /// Every Focus set up on this Mac, for picking the one a profile switches on with.
    @Published private(set) var modes: [FocusMode] = []
    /// A profile switches on with a Focus, so keep reading even while the Focus live activity is off.
    @Published var isNeededByProfiles = false
    /// Notification peeks stay hidden while a Focus is on, as macOS's banners do.
    @Published var isNeededByNotifications = false

    private enum Reading {
        case read(FocusMode?, all: [FocusMode])
        case denied
    }

    nonisolated private static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/DoNotDisturb/DB", isDirectory: true)

    private let queue = DispatchQueue(label: "app.dynotch.focus", qos: .utility)
    private var isWatching = false
    private var hasRead = false
    private var source: DispatchSourceFileSystemObject?
    private var poll: Poll?
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    func start() {
        Publishers.CombineLatest3(AppSettings.shared.$liveFocus, $isNeededByProfiles, $isNeededByNotifications)
            .map { $0 || $1 || $2 }
            .removeDuplicates()
            .sink { [weak self] on in on ? self?.watch() : self?.stopWatching() }
            .store(in: &cancellables)
    }

    /// Full Disk Access can only be given in System Settings, so this opens it there, then looks again.
    func requestAccess() {
        if access != .granted { CalendarService.openPrivacySettings("Privacy_AllFiles") }
        refresh()
    }

    // MARK: Watching

    private func watch() {
        guard !isWatching else { return }
        isWatching = true
        hasRead = false
        // Schedules change without touching the files, so look again now and then, and when
        // someone's back after the displays slept, since a schedule may have started meanwhile.
        poll = EnergyCoordinator.shared.schedule(.focusSchedules) { [weak self] in self?.refresh() }
        refresh()
    }

    private func stopWatching() {
        isWatching = false
        poll?.cancel()
        poll = nil
        source?.cancel()
        source = nil
        mode = nil
    }

    private func refresh() {
        guard isWatching else { return }
        queue.async {
            let reading = Self.read(at: .now)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.apply(reading) }
            }
        }
    }

    private func apply(_ reading: Reading) {
        guard isWatching else { return }
        switch reading {
        case .denied:
            access = .denied
            source?.cancel()
            source = nil
            mode = nil
            hasRead = false
        case .read(let next, let all):
            access = .granted
            if source == nil { openSource() }
            // No notice for whatever was already on when the first look happened.
            if hasRead, next != mode { announce(from: mode, to: next) }
            if next != mode { mode = next }
            if all != modes { modes = all }
            hasRead = true
        }
    }

    private func announce(from previous: FocusMode?, to next: FocusMode?) {
        guard AppSettings.shared.liveFocus else { return }
        let notice: LiveNotice
        if let next {
            notice = LiveNotice(key: "focus", symbol: next.symbol, tint: next.tint, text: "On", detail: next.name,
                                timing: .perishes)
        } else if let previous {
            notice = LiveNotice(key: "focus", symbol: previous.symbol, tint: Color.white.opacity(0.6), text: "Off",
                                detail: previous.name, timing: .perishes)
        } else {
            return
        }
        LiveActivityCenter.shared.post(notice, for: 3)
    }

    /// Changes to the database folder, like a Focus turned on from Control Center.
    private func openSource() {
        let descriptor = open(Self.folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    // MARK: Reading the database

    nonisolated private static func read(at now: Date) -> Reading {
        let assertions: Any?, configurations: Any?
        do {
            assertions = try json(folder.appendingPathComponent("Assertions.json"))
            configurations = try json(folder.appendingPathComponent("ModeConfigurations.json"))
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            return .denied
        } catch {
            return .read(nil, all: [])
        }
        return .read(activeMode(assertions: assertions, configurations: configurations, at: now),
                     all: allModes(configurations: configurations))
    }

    /// Each Focus in the configurations, by name.
    nonisolated static func allModes(configurations: Any?) -> [FocusMode] {
        entries(configurations).compactMap { $0["modeConfigurations"] as? [String: Any] }
            .flatMap { group in group.map { mode(id: $0.key, config: $0.value as? [String: Any]) } }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    nonisolated private static func json(_ url: URL) throws -> Any? {
        do {
            return try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    /// A Focus turned on by hand wins; otherwise one whose schedule covers `now`, unless it was
    /// switched off since that stretch of its schedule began.
    nonisolated static func activeMode(assertions: Any?, configurations: Any?, at now: Date) -> FocusMode? {
        let configs = entries(configurations).compactMap { $0["modeConfigurations"] as? [String: Any] }
            .reduce(into: [String: [String: Any]]()) { all, group in
                for (id, config) in group { if let config = config as? [String: Any] { all[id] = config } }
            }
        let stores = entries(assertions)
        let records = stores.flatMap { $0["storeAssertionRecords"] as? [[String: Any]] ?? [] }
        let latest = records.max { timestamp($0) < timestamp($1) }
        if let details = latest?["assertionDetails"] as? [String: Any],
           let id = details["assertionDetailsModeIdentifier"] as? String {
            return mode(id: id, config: configs[id])
        }
        for (id, config) in configs.sorted(by: { $0.key < $1.key }) {
            guard let start = scheduleStart(config, at: now), !isSwitchedOff(id, since: start, in: stores) else { continue }
            return mode(id: id, config: config)
        }
        return nil
    }

    nonisolated private static func entries(_ json: Any?) -> [[String: Any]] {
        (json as? [String: Any])?["data"] as? [[String: Any]] ?? []
    }

    nonisolated private static func timestamp(_ record: [String: Any]) -> Double {
        (record["assertionStartDateTimestamp"] as? NSNumber)?.doubleValue ?? 0
    }

    /// The database counts time in seconds since 2001, like NSDate.
    nonisolated private static func date(_ value: Any?) -> Date? {
        (value as? NSNumber).map { Date(timeIntervalSinceReferenceDate: $0.doubleValue) }
    }

    /// Whether a Focus was switched off since `start`. macOS notes when everything was last switched
    /// off, and keeps the assertions that ended. Which of the two a scheduled Focus leaves when it's
    /// switched off by hand isn't documented, so this looks for both.
    nonisolated private static func isSwitchedOff(_ id: String, since start: Date, in stores: [[String: Any]]) -> Bool {
        stores.contains { store in
            if let all = date(store["storeLastCompleteInvalidationTimestamp"]), all >= start { return true }
            let ended = store["storeInvalidationRecords"] as? [[String: Any]] ?? []
            return ended.contains { record in
                let details = (record["invalidationAssertion"] as? [String: Any])?["assertionDetails"] as? [String: Any]
                guard details?["assertionDetailsModeIdentifier"] as? String == id,
                      let when = date(record["invalidationDateTimestamp"]) else { return false }
                return when >= start
            }
        }
    }

    /// When the stretch of an enabled time schedule that covers `now` began, overnight ones included.
    nonisolated private static func scheduleStart(_ config: [String: Any], at now: Date) -> Date? {
        let triggers = (config["triggers"] as? [String: Any])?["triggers"] as? [[String: Any]] ?? []
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.hour, .minute, .weekday], from: now)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return triggers.compactMap { trigger -> Date? in
            func value(_ key: String) -> Int? { (trigger[key] as? NSNumber)?.intValue }
            guard value("enabledSetting") == 2,
                  let startHour = value("timePeriodStartTimeHour"), let endHour = value("timePeriodEndTimeHour") else { return nil }
            let startMinute = value("timePeriodStartTimeMinute") ?? 0
            let start = startHour * 60 + startMinute
            let end = endHour * 60 + (value("timePeriodEndTimeMinute") ?? 0)
            guard start != end else { return nil }
            let inside = start < end ? (minute >= start && minute < end) : (minute >= start || minute < end)
            guard inside else { return nil }
            // An overnight schedule belongs to the day it started. Days are bits from Sunday.
            let startedYesterday = start > end && minute < end
            if let days = value("timePeriodWeekdays"), days != 0, let weekday = parts.weekday {
                let startDay = startedYesterday ? (weekday + 5) % 7 + 1 : weekday
                guard days & (1 << (startDay - 1)) != 0 else { return nil }
            }
            guard let today = calendar.date(bySettingHour: startHour, minute: startMinute, second: 0, of: now) else { return nil }
            return startedYesterday ? calendar.date(byAdding: .day, value: -1, to: today) : today
        }.max()
    }

    nonisolated private static func mode(id: String, config: [String: Any]?) -> FocusMode {
        let details = config?["mode"] as? [String: Any] ?? [:]
        let name = (details["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Focus"
        let symbol = (details["symbolImageName"] as? String)
            .flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil ? nil : $0 } ?? "moon.fill"
        return FocusMode(id: id, name: name, symbol: symbol, tint: tint(named: details["tintColorName"] as? String))
    }

    /// "systemIndigoColor" and the like.
    nonisolated private static func tint(named name: String?) -> Color {
        let key = (name ?? "").lowercased().replacingOccurrences(of: "system", with: "").replacingOccurrences(of: "color", with: "")
        let colors: [String: Color] = ["indigo": .indigo, "purple": .purple, "blue": .blue, "teal": .teal, "cyan": .cyan,
                                       "green": .green, "mint": .mint, "yellow": .yellow, "orange": .orange, "red": .red,
                                       "pink": .pink, "brown": .brown, "gray": .gray, "grey": .gray]
        return colors[key] ?? .indigo
    }

    // MARK: Report

    /// Saves what the Focus database holds and which Focus Dynotch makes of it, for checking how
    /// macOS records a Focus, to a file the user picks. Names and places are left out, so the
    /// report can be shared. It's a button in Settings rather than a `dynotch://` link: the files
    /// are behind Full Disk Access, and a link can come from anything on the Mac.
    func saveReport() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.title = "Save Focus Report"
        panel.nameFieldStringValue = "focus-report.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        queue.async {
            let now = Date.now
            var report: [String: Any] = ["time": now.formatted(.iso8601), "timestamp": now.timeIntervalSinceReferenceDate]
            do {
                let assertions = try Self.json(Self.folder.appendingPathComponent("Assertions.json"))
                let configurations = try Self.json(Self.folder.appendingPathComponent("ModeConfigurations.json"))
                report["shows"] = Self.activeMode(assertions: assertions, configurations: configurations, at: now)?.id ?? NSNull()
                report["assertions"] = assertions.map { Self.redacted($0) } ?? NSNull()
                report["configurations"] = configurations.map { Self.redacted($0) } ?? NSNull()
            } catch let error as CocoaError where error.code == .fileReadNoPermission {
                report["error"] = "Dynotch has no Full Disk Access"
            } catch {
                report["error"] = error.localizedDescription
            }
            guard JSONSerialization.isValidJSONObject(report),
                  let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Keeps the shape, the numbers and the identifiers. Other text, such as a Focus's name, becomes
    /// its length, and coordinates are left out.
    nonisolated private static func redacted(_ value: Any, key: String = "") -> Any {
        let key = key.lowercased()
        switch value {
        case let dictionary as [String: Any]:
            return dictionary.reduce(into: [String: Any]()) { $0[$1.key] = redacted($1.value, key: $1.key) }
        case let array as [Any]:
            return array.map { redacted($0, key: key) }
        case let text as String:
            let kept = ["identifier", "uuid", "reason", "type", "behavior", "colorname", "imagename", "class"]
            return kept.contains { key.hasSuffix($0) } ? text : "\(text.count) characters"
        case is NSNumber where ["latitude", "longitude", "radius"].contains(where: { key.hasSuffix($0) }):
            return "left out"
        default:
            return value
        }
    }

    // MARK: Snapshots

    func loadSample(_ mode: FocusMode?, all: [FocusMode] = []) {
        self.mode = mode
        modes = all
        access = .granted
    }
}
