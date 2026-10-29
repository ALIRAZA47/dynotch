import AVFoundation
import Combine
import CoreServices
import SwiftUI

/// Where each privacy permission stands, for the Permissions page and its header.
@MainActor
final class PermissionStatus: ObservableObject {
    static let shared = PermissionStatus()

    enum State: Equatable {
        case granted, denied, notDetermined
        case unavailable(String)
    }

    struct Item: Identifiable {
        let title: String
        let purpose: String
        let symbol: String
        /// The badge's color. Without one, the window accent.
        var tint: Color?
        /// Shown instead of the symbol: the app that the permission is for.
        var appBundleID: String?
        /// False when macOS never asks, like Full Disk Access: the button opens System Settings.
        var hasPrompt = true
        let state: State
        let action: () -> Void

        var id: String { title }
    }

    @Published private var automation: [String: Automation.Status] = [:]
    private var cancellables = Set<AnyCancellable>()

    /// System Events has no icon of its own worth showing, so it gets a symbol.
    private let automationTargets: [(name: String, bundleID: String, purpose: String, showsIcon: Bool)] = [
        ("Music", "com.apple.Music", "Now playing and playback controls", true),
        ("Spotify", "com.spotify.client", "Now playing and playback controls", true),
        ("System Events", "com.apple.systemevents", "The Dark Mode quick toggle", false),
    ]

    private init() {
        Publishers.Merge3(CalendarService.shared.objectWillChange, CameraService.shared.objectWillChange,
                          DeviceBatteryMonitor.shared.objectWillChange)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        Publishers.Merge3(NotificationMirror.shared.objectWillChange, MediaKeyTap.shared.objectWillChange,
                          AudioLevels.shared.$permission.map { _ in () })
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        DownloadMonitor.shared.$access
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        FocusMonitor.shared.$access
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        Publishers.Merge(ScreenshotWatcher.shared.objectWillChange, WeatherService.shared.objectWillChange)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        CaptureController.shared.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    var privacy: [Item] {
        let calendar = CalendarService.shared
        let camera = CameraService.shared
        let devices = DeviceBatteryMonitor.shared
        return [
            Item(title: "Calendar", purpose: "Upcoming events in the Nook", symbol: "calendar", tint: .red,
                 state: state(calendar.eventAccess == .fullAccess, undetermined: calendar.eventAccess == .notDetermined),
                 action: calendar.requestEventAccess),
            Item(title: "Reminders", purpose: "Your list on the Focus tab", symbol: "checklist", tint: .orange,
                 state: state(calendar.reminderAccess == .fullAccess, undetermined: calendar.reminderAccess == .notDetermined),
                 action: calendar.requestReminderAccess),
            Item(title: "Camera", purpose: "The Mirror widget", symbol: "camera.fill", tint: .teal,
                 state: state(camera.status == .authorized, undetermined: camera.status == .notDetermined),
                 action: camera.requestAccess),
            // macOS doesn't say whether Accessibility was refused or never asked for.
            Item(title: "Accessibility", purpose: "The volume and brightness keys, with the system HUD replaced",
                 symbol: "accessibility", tint: .indigo, state: MediaKeyTap.shared.hasAccess ? .granted : .notDetermined,
                 action: MediaKeyTap.shared.requestAccess),
            Item(title: "System audio recording", purpose: "The live equalizer, which listens to Music and Spotify",
                 symbol: "waveform", tint: .pink, state: audioCaptureState, action: AudioLevels.shared.requestPermission),
            Item(title: "Bluetooth", purpose: "Battery levels of AirPods, keyboards and mice, and connecting them", symbol: "airpodspro",
                 tint: .blue, state: devices.isAuthorized ? .granted : .notDetermined, action: devices.requestAccess),
            screenRecordingItem,
            downloadsItem,
            fullDiskAccessItem,
        ] + (AppSettings.shared.screenshotsToTray ? [screenshotsItem] : [])
            + (AppSettings.shared.weatherUsesLocation ? [locationItem] : [])
    }

    /// macOS asks once, when the first capture is taken; after a refusal the button opens System Settings.
    private var screenRecordingItem: Item {
        let capture = CaptureController.shared
        let state: State = capture.hasAccess ? .granted : capture.hasAsked ? .denied : .notDetermined
        return Item(title: "Screen Recording", purpose: "Capturing part of the screen with ⌃⌥S", symbol: "rectangle.dashed.badge.record",
                    tint: .purple, state: state, action: capture.requestAccess)
    }

    /// Only asked for when the Weather widget is set to use where the Mac is.
    private var locationItem: Item {
        let weather = WeatherService.shared
        let state: State = weather.isLocationAllowed ? .granted
            : weather.locationAccess == .notDetermined ? .notDetermined : .denied
        return Item(title: "Location", purpose: "Weather where you are", symbol: "location.fill", tint: .blue,
                    state: state, action: weather.requestLocationAccess)
    }

    /// Reading the folder screenshots are saved to. macOS asks for the Desktop, Documents and Downloads.
    private var screenshotsItem: Item {
        let watcher = ScreenshotWatcher.shared
        let state: State
        switch watcher.access {
        case .granted: state = .granted
        case .denied: state = .denied
        case .unknown: state = .notDetermined
        }
        return Item(title: "Screenshots folder", purpose: "New screenshots in the Tray (\(ScreenshotWatcher.folderNames))",
                    symbol: "camera.viewfinder", tint: .orange, state: state) {
            if watcher.access == .denied {
                CalendarService.openPrivacySettings("Privacy_FilesAndFolders")
            } else {
                watcher.restart()
            }
        }
    }

    /// There's no prompt for Full Disk Access; the button opens its pane in System Settings.
    /// One switch in System Settings serves both readers, so either one seeing its file means it's on.
    /// There's no prompt for Full Disk Access, only that switch.
    private var fullDiskAccessItem: Item {
        let focus = FocusMonitor.shared
        let state: State = if NotificationMirror.shared.hasAccess || focus.access == .granted {
            .granted
        } else {
            focus.access == .unknown ? .notDetermined : .denied
        }
        return Item(title: "Full Disk Access", purpose: "Notification peeks and the Focus that's on",
                    symbol: "internaldrive.fill", tint: .gray, hasPrompt: false, state: state,
                    action: NotificationMirror.shared.openAccessSettings)
    }

    private var downloadsItem: Item {
        let downloads = DownloadMonitor.shared
        let state: State = switch downloads.access {
        case .granted: .granted
        case .denied: .denied
        case .unknown: .notDetermined
        }
        return Item(title: "Downloads folder", purpose: "Download progress in the notch, and finished files in the Tray",
                    symbol: "arrow.down.circle.fill", tint: .blue, state: state, action: downloads.requestAccess)
    }

    var automationItems: [Item] {
        automationTargets.map { target in
            let status = automation[target.bundleID] ?? .unknown
            return Item(title: target.name, purpose: target.purpose, symbol: "gearshape.2.fill", tint: .gray,
                        appBundleID: target.showsIcon ? target.bundleID : nil, state: automationState(status)) { [weak self] in
                if status == .denied {
                    CalendarService.openPrivacySettings("Privacy_Automation")
                } else {
                    Task { self?.automation[target.bundleID] = await Automation.status(of: target.bundleID, ask: true) }
                }
            }
        }
    }

    var grantedCount: Int { (privacy + automationItems).filter { $0.state == .granted }.count }
    var totalCount: Int { privacy.count + automationTargets.count }

    func refreshAutomation() async {
        for target in automationTargets {
            automation[target.bundleID] = await Automation.status(of: target.bundleID, ask: false)
        }
    }

    private func state(_ granted: Bool, undetermined: Bool) -> State {
        granted ? .granted : undetermined ? .notDetermined : .denied
    }

    private var audioCaptureState: State {
        guard AudioLevels.isSupported else { return .unavailable("Needs macOS 14.2") }
        switch AudioLevels.shared.permission {
        case .granted: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        case .unknown: return .unavailable("Asked for when the equalizer starts")
        }
    }

    private func automationState(_ status: Automation.Status) -> State {
        switch status {
        case .granted: .granted
        case .denied: .denied
        case .notDetermined: .notDetermined
        case .notRunning: .unavailable("Open the app to check")
        case .unknown: .unavailable("Checking…")
        }
    }
}

struct PermissionsSettings: View {
    @ObservedObject private var status = PermissionStatus.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            SettingsSection(title: "Privacy", footer: "Dynotch only asks for what a feature needs, the first time you use it.") {
                rows(status.privacy)
            }
            SettingsSection(title: "Automation", footer: "macOS can only report on an app that's open.") {
                rows(status.automationItems)
            }
        }
        .task { await status.refreshAutomation() }
    }

    private func rows(_ items: [PermissionStatus.Item]) -> some View {
        SettingsCard {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { CardDivider() }
                PermissionRow(item: item)
            }
        }
    }
}

/// A permission, what it's for, and where it stands, with a button to ask for it.
struct PermissionRow: View {
    let item: PermissionStatus.Item

    var body: some View {
        HStack(spacing: 12) {
            // App icons and symbols take the same width, so the titles line up.
            Group {
                if let bundleID = item.appBundleID {
                    AppIconView(bundleID: bundleID, fallback: "app.fill", side: 30)
                } else {
                    SymbolBadge(symbol: item.symbol, tint: item.tint, size: 28)
                }
            }
            .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                Text(item.purpose)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.secondaryText)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            switch item.state {
            case .granted:
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .modifier(CheckCapsule())
            case .denied:
                openSettingsButton
            case .notDetermined where !item.hasPrompt:
                openSettingsButton
            case .notDetermined:
                CapsuleButton(title: "Allow…", kind: .prominent, action: item.action)
                    .accessibilityLabel("Allow \(item.title)…")
            case .unavailable(let reason):
                Text(reason)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.secondaryText)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var openSettingsButton: some View {
        CapsuleButton(title: "Open System Settings", symbol: "arrow.up.forward", action: item.action)
            .accessibilityLabel("Open System Settings for \(item.title)")
    }
}

/// A green check and a word in a quiet green capsule: a permission that's allowed, a profile that's
/// on. The green is the window's shade of it, deep enough to read on the light page, and its capsule
/// is fainter there, as a selected chip's is, so the word keeps 4.5:1.
struct CheckCapsule: ViewModifier {
    var width: CGFloat?
    @Environment(\.colorScheme) private var colorScheme

    private static let green = WindowAccent(choice: .green).color

    func body(content: Content) -> some View {
        content
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Self.green)
            .padding(.horizontal, 10)
            .frame(width: width, height: 26)
            .background(Capsule().fill(Self.green.opacity(colorScheme == .dark ? 0.12 : 0.06)))
    }
}

/// Apple Events permission, checked without sending an event.
enum Automation {
    enum Status {
        case granted, denied, notDetermined, notRunning, unknown
    }

    static func status(of bundleID: String, ask: Bool) async -> Status {
        await withCheckedContinuation { continuation in
            // This can block while macOS shows its prompt, so keep it off the main thread.
            DispatchQueue.global(qos: .userInitiated).async {
                let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
                let result = AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(typeWildCard),
                                                                   AEEventID(typeWildCard), ask)
                let status: Status
                switch result {
                case noErr: status = .granted
                case OSStatus(errAEEventNotPermitted): status = .denied
                case OSStatus(errAEEventWouldRequireUserConsent): status = .notDetermined
                case OSStatus(procNotFound): status = .notRunning
                default: status = .unknown
                }
                continuation.resume(returning: status)
            }
        }
    }
}
