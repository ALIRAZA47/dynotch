import AppKit
import Combine
import SwiftUI

/// Shows other apps' notifications in the closed notch as they arrive: the app's symbol, the sender
/// and a line of text. Reads them through `NotificationReader`, which needs Full Disk Access.
/// Nothing a notification says is logged or stored.
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

    private func readerStopped(_ problem: NotificationReader.Problem) {
        isWatching = false
        hasAccess = problem != .noAccess
        isUnsupported = problem == .unsupported
    }

    /// The newest notification wins; the ones before it already had their moment.
    private func show(_ entries: [NotificationReader.Entry]) {
        let settings = AppSettings.shared
        guard settings.liveNotifications,
              let entry = entries.last(where: { $0.bundleID != Bundle.main.bundleIdentifier && isShown($0.bundleID) })
        else { return }
        let notice = NotificationPeek.notice(for: entry, appName: appName(for: entry.bundleID),
                                             hideText: settings.notificationHideText)
        LiveActivityCenter.shared.post(notice, for: 5)
    }
}

/// How a notification looks in the notch. Apps with a symbol of their own are listed in `sources`;
/// any other app gets a bell.
enum NotificationPeek {
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
    /// instead, so only the app and the sender show.
    static func notice(for entry: NotificationReader.Entry, appName: String, hideText: Bool) -> LiveNotice {
        let source = source(for: entry.bundleID)
        let sender = entry.title.isEmpty ? appName : entry.title
        var line = [entry.subtitle, entry.body].filter { !$0.isEmpty }.joined(separator: " · ")
        // A bell doesn't say which app it was, so the text does.
        if source == nil, !line.isEmpty { line = "\(appName): \(line)" }
        let detail = hideText || line.isEmpty ? (sender == appName ? nil : appName) : String(line.prefix(160))
        return LiveNotice(key: "notification", symbol: source?.symbol ?? "bell.badge.fill", tint: source?.tint ?? .white,
                          text: shortened(sender, to: 16), detail: detail)
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
