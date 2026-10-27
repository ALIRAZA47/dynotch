import AppKit
import Combine
import SwiftUI

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

    private enum Reading {
        case read(FocusMode?)
        case denied
    }

    nonisolated private static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/DoNotDisturb/DB", isDirectory: true)

    private let queue = DispatchQueue(label: "app.dynotch.focus", qos: .utility)
    private var isWatching = false
    private var hasRead = false
    private var source: DispatchSourceFileSystemObject?
    private var poll: Timer?
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    func start() {
        AppSettings.shared.$liveFocus
            .removeDuplicates()
            .sink { [weak self] on in on ? self?.watch() : self?.stopWatching() }
            .store(in: &cancellables)
        // A schedule can start or end while the Mac sleeps.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.refresh() }
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
        // Schedules change without touching the files, so look again now and then.
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
        refresh()
    }

    private func stopWatching() {
        isWatching = false
        poll?.invalidate()
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
        case .read(let next):
            access = .granted
            if source == nil { openSource() }
            // No notice for whatever was already on when the first look happened.
            if hasRead, next != mode { announce(from: mode, to: next) }
            if next != mode { mode = next }
            hasRead = true
        }
    }

    private func announce(from previous: FocusMode?, to next: FocusMode?) {
        guard AppSettings.shared.liveFocus else { return }
        let notice: LiveNotice
        if let next {
            notice = LiveNotice(key: "focus", symbol: next.symbol, tint: next.tint, text: "On", detail: next.name)
        } else if let previous {
            notice = LiveNotice(key: "focus", symbol: previous.symbol, tint: Color.white.opacity(0.6), text: "Off",
                                detail: previous.name)
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
            return .read(nil)
        }
        return .read(activeMode(assertions: assertions, configurations: configurations, at: now))
    }

    nonisolated private static func json(_ url: URL) throws -> Any? {
        do {
            return try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    /// A Focus turned on by hand wins; otherwise one whose schedule covers `now`.
    nonisolated static func activeMode(assertions: Any?, configurations: Any?, at now: Date) -> FocusMode? {
        let configs = entries(configurations).compactMap { $0["modeConfigurations"] as? [String: Any] }
            .reduce(into: [String: [String: Any]]()) { all, group in
                for (id, config) in group { if let config = config as? [String: Any] { all[id] = config } }
            }
        let records = entries(assertions).flatMap { $0["storeAssertionRecords"] as? [[String: Any]] ?? [] }
        let latest = records.max { timestamp($0) < timestamp($1) }
        if let details = latest?["assertionDetails"] as? [String: Any],
           let id = details["assertionDetailsModeIdentifier"] as? String {
            return mode(id: id, config: configs[id])
        }
        for (id, config) in configs.sorted(by: { $0.key < $1.key }) where isScheduled(config, at: now) {
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

    /// An enabled time schedule that covers `now`, overnight ones included.
    nonisolated private static func isScheduled(_ config: [String: Any], at now: Date) -> Bool {
        let triggers = (config["triggers"] as? [String: Any])?["triggers"] as? [[String: Any]] ?? []
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.hour, .minute, .weekday], from: now)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return triggers.contains { trigger in
            func value(_ key: String) -> Int? { (trigger[key] as? NSNumber)?.intValue }
            guard value("enabledSetting") == 2,
                  let startHour = value("timePeriodStartTimeHour"), let endHour = value("timePeriodEndTimeHour") else { return false }
            let start = startHour * 60 + (value("timePeriodStartTimeMinute") ?? 0)
            let end = endHour * 60 + (value("timePeriodEndTimeMinute") ?? 0)
            guard start != end else { return false }
            let inside = start < end ? (minute >= start && minute < end) : (minute >= start || minute < end)
            guard inside else { return false }
            // Days as bits from Sunday; an overnight schedule belongs to the day it started.
            guard let days = value("timePeriodWeekdays"), days != 0, let weekday = parts.weekday else { return true }
            let startDay = start > end && minute < end ? (weekday + 5) % 7 + 1 : weekday
            return days & (1 << (startDay - 1)) != 0
        }
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

    // MARK: Snapshots

    func loadSample(_ mode: FocusMode?) {
        self.mode = mode
        access = .granted
    }
}
