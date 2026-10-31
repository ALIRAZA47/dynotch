import AppKit
import Combine
import SwiftUI

/// Shows other apps' notifications in the closed notch as they arrive: the app's symbol, the sender
/// and a line of text. Reads them through `NotificationReader`, which needs Full Disk Access.
/// Nothing a notification says is logged or stored. Like macOS's own banners, peeks stay hidden
/// while a Focus is on and while a display is mirrored.
@MainActor
final class NotificationMirror: ObservableObject {
    static let shared = NotificationMirror()

    /// Whether Dynotch may read Notification Center's database, which takes Full Disk Access.
    @Published private(set) var hasAccess = false
    /// Set when the database can't be read even with access: a macOS version that keeps it elsewhere.
    @Published private(set) var isUnsupported = false

    private let reader = NotificationReader()
    private var isStarted = false
    private var isWatching = false
    private var names: [String: String] = [:]
    /// How many came from each app during the Focus that's on. Never what they said.
    private var missed: [String: Int] = [:]
    private var focusName: String?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        refreshAccess()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        AppSettings.shared.$liveNotifications
            .removeDuplicates()
            .sink { [weak self] enabled in self?.update(enabled: enabled) }
            .store(in: &cancellables)
        // Coming back from System Settings, where Full Disk Access is turned on.
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refreshAccess() }
            .store(in: &cancellables)
        FocusMonitor.shared.$mode
            .removeDuplicates()
            .sink { [weak self] mode in self?.focusChanged(to: mode) }
            .store(in: &cancellables)
    }

    /// Checks Full Disk Access again, and starts or stops watching to match. Settings calls this
    /// every few seconds while it waits, so it only publishes changes.
    func refreshAccess() {
        let problem = reader.problem()
        let hasAccess = problem != .noAccess, isUnsupported = problem == .unsupported
        if self.hasAccess != hasAccess { self.hasAccess = hasAccess }
        if self.isUnsupported != isUnsupported { self.isUnsupported = isUnsupported }
        update(enabled: AppSettings.shared.liveNotifications)
    }

    /// Full Disk Access has no prompt; it's turned on in System Settings.
    func openAccessSettings() {
        CalendarService.openPrivacySettings("Privacy_AllFiles")
    }

    /// The app's name as Finder shows it.
    func appName(for bundleID: String) -> String {
        if let name = names[bundleID] { return name }
        let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { url in
            let name = FileManager.default.displayName(atPath: url.path)
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
        let name = installed ?? NotificationPeek.source(for: bundleID)?.name
            ?? bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        names[bundleID] = name
        return name
    }

    /// Whether the app's notifications peek, as chosen in Settings.
    func isShown(_ bundleID: String) -> Bool {
        let settings = AppSettings.shared
        if let source = NotificationPeek.source(for: bundleID) {
            return !settings.notificationMutedApps.contains(source.id)
        }
        return settings.notificationOtherApps
    }

    // MARK: Private

    private func update(enabled: Bool) {
        let shouldWatch = isStarted && enabled && hasAccess && !isUnsupported
        guard shouldWatch != isWatching else { return }
        isWatching = shouldWatch
        FocusMonitor.shared.isNeededByNotifications = shouldWatch
        if shouldWatch {
            reader.start { entries in
                Task { @MainActor in NotificationMirror.shared.show(entries) }
            } failure: { problem in
                Task { @MainActor in NotificationMirror.shared.readerStopped(problem) }
            }
        } else {
            reader.stop()
        }
    }

    /// Whether a display is mirrored to another, over a cable or AirPlay.
    private static var isAnyDisplayMirrored: Bool {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &displays, &count) == .success else { return false }
        return displays.prefix(Int(count)).contains { CGDisplayIsInMirrorSet($0) != 0 }
    }

    private func readerStopped(_ problem: NotificationReader.Problem) {
        isWatching = false
        hasAccess = problem != .noAccess
        isUnsupported = problem == .unsupported
    }

    private func show(_ entries: [NotificationReader.Entry]) {
        let settings = AppSettings.shared
        guard settings.liveNotifications else { return }
        let shown = entries.filter { $0.bundleID != Bundle.main.bundleIdentifier && isShown($0.bundleID) }
        // What macOS holds its own banners back for: a Focus, and a display that's mirrored or
        // shared. Mirroring can be seen from here; sharing can't, which is what Hide message text is for.
        if FocusMonitor.shared.mode != nil {
            for entry in shown { missed[appName(for: entry.bundleID), default: 0] += 1 }
            return
        }
        guard !Self.isAnyDisplayMirrored else { return }
        QuietMonitor.shared.look()
        // macOS saves a burst in one go. They take turns; a long burst leaves its oldest to the banners.
        for entry in shown.suffix(3) {
            let notice = NotificationPeek.notice(for: entry, appName: appName(for: entry.bundleID),
                                                 hideText: settings.notificationHideText,
                                                 findsCodes: settings.notificationCodes, isQuiet: QuietMonitor.shared.isQuiet)
            LiveActivityCenter.shared.post(notice, for: 5)
        }
    }

    /// Whether a peek that waited out a call should stay hidden after all: a Focus came on while it
    /// waited, in which case it counts as missed, or a display is mirrored now.
    func holdsBack(_ notice: LiveNotice) -> Bool {
        guard notice.isPeek else { return false }
        if FocusMonitor.shared.mode != nil {
            if case .name(let app) = notice.recall { missed[app, default: 0] += 1 }
            return true
        }
        return Self.isAnyDisplayMirrored
    }

    /// When a Focus ends, one line on what came in during it.
    private func focusChanged(to mode: FocusMode?) {
        if let mode {
            focusName = mode.name
            return
        }
        defer {
            missed = [:]
            focusName = nil
        }
        guard let focusName, !missed.isEmpty, AppSettings.shared.notificationDigest else { return }
        LiveActivityCenter.shared.post(NotificationPeek.digest(of: missed, during: focusName), for: 8)
    }
}

/// How a notification looks in the notch. Apps with a symbol of their own are listed in `sources`;
/// any other app gets a bell.
enum NotificationPeek {
    /// What a peek's key starts with. The rest is who it's from.
    static let keyPrefix = "notification-"

    struct Source: Identifiable, Sendable {
        let name: String
        let symbol: String
        let tint: Color
        /// The first is the app's current ID; the others are older or alternative builds.
        let bundleIDs: [String]

        var id: String { bundleIDs[0] }
    }

    static let sources: [Source] = [
        Source(name: "Messages", symbol: "message.fill", tint: Color(red: 0.27, green: 0.85, blue: 0.42),
               bundleIDs: ["com.apple.MobileSMS"]),
        Source(name: "Mail", symbol: "envelope.fill", tint: Color(red: 0.31, green: 0.62, blue: 1.0),
               bundleIDs: ["com.apple.mail"]),
        Source(name: "Slack", symbol: "number.square.fill", tint: Color(red: 0.93, green: 0.42, blue: 0.69),
               bundleIDs: ["com.tinyspeck.slackmacgap"]),
        Source(name: "Microsoft Teams", symbol: "person.2.fill", tint: Color(red: 0.55, green: 0.57, blue: 1.0),
               bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"]),
        Source(name: "Outlook", symbol: "envelope.fill", tint: Color(red: 0.16, green: 0.6, blue: 0.94),
               bundleIDs: ["com.microsoft.Outlook"]),
        Source(name: "WhatsApp", symbol: "phone.bubble.fill", tint: Color(red: 0.3, green: 0.85, blue: 0.47),
               bundleIDs: ["net.whatsapp.WhatsApp", "desktop.WhatsApp"]),
        Source(name: "Telegram", symbol: "paperplane.fill", tint: Color(red: 0.36, green: 0.7, blue: 1.0),
               bundleIDs: ["ru.keepcoder.Telegram", "org.telegram.desktop"]),
        Source(name: "Signal", symbol: "bubble.left.fill", tint: Color(red: 0.4, green: 0.55, blue: 1.0),
               bundleIDs: ["org.whispersystems.signal-desktop"]),
        Source(name: "Discord", symbol: "gamecontroller.fill", tint: Color(red: 0.53, green: 0.56, blue: 1.0),
               bundleIDs: ["com.hnc.Discord"]),
        Source(name: "FaceTime", symbol: "video.fill", tint: Color(red: 0.27, green: 0.85, blue: 0.42),
               bundleIDs: ["com.apple.FaceTime"]),
        Source(name: "Zoom", symbol: "video.fill", tint: Color(red: 0.3, green: 0.58, blue: 1.0),
               bundleIDs: ["us.zoom.xos"]),
        Source(name: "Calendar", symbol: "calendar", tint: Color(red: 1.0, green: 0.38, blue: 0.35),
               bundleIDs: ["com.apple.iCal"]),
        Source(name: "Reminders", symbol: "checklist", tint: .orange,
               bundleIDs: ["com.apple.reminders"]),
    ]

    static func source(for bundleID: String) -> Source? {
        sources.first { $0.bundleIDs.contains(bundleID) }
    }

    /// The sender beside the camera and the text underneath. With `hideText`, the row names the app
    /// instead, so only the app and the sender show. A login code gets a button and doesn't wait: it's
    /// for the sign-in you're doing, so on a call it shows anyway, with its text off the screen.
    static func notice(for entry: NotificationReader.Entry, appName: String, hideText: Bool,
                       findsCodes: Bool = false, isQuiet: Bool = false) -> LiveNotice {
        let code = findsCodes ? OneTimeCode.find(title: entry.title, subtitle: entry.subtitle, body: entry.body) : nil
        let hideText = hideText || (code != nil && isQuiet)
        let source = source(for: entry.bundleID)
        // Some apps put the code in the title, so with the text hidden the sender goes too.
        let sender = entry.title.isEmpty || (code != nil && hideText) ? appName : entry.title
        var line = [entry.subtitle, entry.body].filter { !$0.isEmpty }.joined(separator: " · ")
        // A bell doesn't say which app it was, so the text does.
        if source == nil, !line.isEmpty { line = "\(appName): \(line)" }
        let detail = code != nil && hideText ? "Login code"
            : hideText || line.isEmpty ? (sender == appName ? nil : appName) : String(line.prefix(160))
        var actions = [NoticeAction(title: "Open", kind: .openApp(bundleID: entry.bundleID))]
        if let code { actions.insert(NoticeAction(title: "Copy Code", kind: .copyCode(code)), at: 0) }
        // Keyed by who it's from, so a second message from them updates the first, and anyone else's waits its turn.
        return LiveNotice(key: "\(keyPrefix)\(entry.bundleID)-\(sender)", symbol: source?.symbol ?? "bell.badge.fill",
                          tint: source?.tint ?? .white, text: shortened(sender, to: 16), detail: detail, actions: actions,
                          timing: code == nil ? .waits : .always, recall: .name(appName))
    }

    /// "12" beside the camera, and "While you were in Work: Slack 8, Mail 3" underneath.
    static func digest(of missed: [String: Int], during focus: String) -> LiveNotice {
        let total = missed.values.reduce(0, +)
        let apps = missed.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .map { "\($0.key) \($0.value)" }
            .joined(separator: ", ")
        return LiveNotice(key: "missed", symbol: "bell.badge.fill", tint: .indigo, text: "\(total)",
                          detail: "While you were in \(focus): \(apps)", timing: .waits, recall: .whole)
    }

    /// For previews and snapshots.
    static func sample(hideText: Bool = false) -> LiveNotice {
        notice(for: NotificationReader.Entry(bundleID: "com.apple.MobileSMS", title: "Anna", subtitle: "",
                                             body: "Running 5 min late, order me a flat white?"),
               appName: "Messages", hideText: hideText)
    }

    /// The ear beside the camera fits a name, not a sentence.
    private static func shortened(_ text: String, to length: Int) -> String {
        text.count <= length ? text : String(text.prefix(length - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
