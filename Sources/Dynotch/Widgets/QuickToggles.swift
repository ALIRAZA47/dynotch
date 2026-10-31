import AppKit
import IOKit.pwr_mgt
import SwiftUI

/// One-tap system actions for the Stats tab.
@MainActor
final class QuickToggles: ObservableObject {
    static let shared = QuickToggles()

    @Published private(set) var isDarkMode = QuickToggles.systemIsDark()
    @Published private(set) var isKeepingAwake = false
    /// When Keep Awake turns itself off, if it does.
    @Published private(set) var keepAwakeEnd: Date?

    /// "Awake until 5:30 PM", or "Awake" with no end.
    var keepAwakeDescription: String {
        keepAwakeEnd.map { "Awake until \($0.formatted(date: .omitted, time: .shortened))" } ?? "Awake"
    }

    private var assertion: IOPMAssertionID = 0
    private var keepAwakePoll: Poll?
    private let runner = AppleScriptRunner()
    private var observer: NSObjectProtocol?

    private init() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isDarkMode = QuickToggles.systemIsDark() }
        }
    }

    /// Needs permission to control System Events, which macOS asks for the first time.
    func toggleDarkMode() {
        isDarkMode.toggle()
        Task {
            _ = await runner.run("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
            isDarkMode = Self.systemIsDark()
        }
    }

    func toggleKeepAwake() {
        if isKeepingAwake {
            stopKeepingAwake()
        } else {
            keepAwake()
        }
    }

    /// Keeps the display awake, like `caffeinate -d`, until `end`, or until it's turned off.
    func keepAwake(until end: Date? = nil) {
        if !isKeepingAwake {
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "Keep Awake from Dynotch" as CFString, &assertion)
            isKeepingAwake = result == kIOReturnSuccess
        }
        guard isKeepingAwake else { return }
        keepAwakeEnd = end
        keepAwakePoll?.cancel()
        keepAwakePoll = end.map { _ in
            EnergyCoordinator.shared.schedule(.keepAwake, deadline: { [weak self] in self?.keepAwakeEnd }) { [weak self] in
                self?.endKeepAwakeIfDue()
            }
        }
    }

    func stopKeepingAwake() {
        guard isKeepingAwake else { return }
        IOPMAssertionRelease(assertion)
        isKeepingAwake = false
        keepAwakeEnd = nil
        keepAwakePoll?.cancel()
        keepAwakePoll = nil
    }

    private func endKeepAwakeIfDue() {
        guard let end = keepAwakeEnd, end <= .now else { return }
        stopKeepingAwake()
        LiveActivityCenter.shared.post(LiveNotice(key: "awake", symbol: "cup.and.saucer.fill", tint: .orange, text: "",
                                                  detail: "Keep Awake is off", timing: .perishes), for: 3)
    }

    /// Picks a color anywhere on screen and copies its hex code.
    func pickColor() {
        NSColorSampler().show { color in
            guard let color = color?.usingColorSpace(.sRGB) else { return }
            let hex = String(format: "#%02X%02X%02X", Int((color.redComponent * 255).rounded()),
                             Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(hex, forType: .string)
            Task { @MainActor in
                LiveActivityCenter.shared.post(LiveNotice(key: "color", symbol: "circle.fill", tint: Color(nsColor: color),
                                                          text: hex, detail: "Copied to the clipboard"), for: 3)
            }
        }
    }

    /// Dynotch's own capture, with the notch out of the way first.
    func takeScreenshot() {
        NotchManager.shared.close()
        CaptureController.shared.begin()
    }

    func sleepDisplay() {
        Task { await Shell.run("/usr/bin/pmset", ["displaysleepnow"]) }
    }

    // MARK: Snapshots

    /// Keep Awake as a sample: on until `end`, or off. It holds nothing, so the Mac sleeps as usual.
    func loadSample(awakeUntil end: Date?) {
        isKeepingAwake = end != nil
        keepAwakeEnd = end
    }

    private static func systemIsDark() -> Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }
}

/// The quick toggles in a card of their own, for the stack beside the player.
struct QuickTogglesWidget: View {
    var body: some View {
        WidgetCard {
            ControlToggleGrid(spacing: 6)
        }
    }
}

/// Six tiles: Dark Mode, Keep Awake and the microphone, which stay on, then the color picker, a
/// screenshot and sleeping the display, which happen once. A tile that's on turns into a solid
/// jewel of the accent, with ink on it.
struct ControlToggleGrid: View {
    var spacing: CGFloat = 8
    @ObservedObject private var toggles = QuickToggles.shared
    @ObservedObject private var mic = MicMonitor.shared

    var body: some View {
        // Two rows of three, sharing whatever room the notch's size leaves them.
        GeometryReader { proxy in
            let fit = ControlTile.Fit(width: (proxy.size.width - spacing * 2) / 3, height: (proxy.size.height - spacing) / 2)
            VStack(spacing: spacing) {
                HStack(spacing: spacing) {
                    ControlTile(symbol: toggles.isDarkMode ? "moon.fill" : "sun.max.fill", title: "Dark",
                                state: toggles.isDarkMode ? "On" : "Off", isOn: toggles.isDarkMode, fit: fit,
                                action: toggles.toggleDarkMode)
                    ControlTile(symbol: "cup.and.saucer.fill", title: "Awake", state: awakeState,
                                isOn: toggles.isKeepingAwake, fit: fit, action: toggles.toggleKeepAwake)
                        .contextMenu { KeepAwakeMenu() }
                    ControlTile(symbol: mic.isMuted ? "mic.slash.fill" : "mic.fill", title: "Mute mic",
                                state: mic.hasInput ? (mic.isMuted ? "On" : "Off") : "No mic", isOn: mic.isMuted, fit: fit,
                                action: mic.toggleMute)
                        .disabled(!mic.hasInput)
                }
                HStack(spacing: spacing) {
                    ControlTile(symbol: "eyedropper", title: "Color", state: "Copy hex", fit: fit, action: toggles.pickColor)
                    ControlTile(symbol: "camera.viewfinder", title: "Capture", state: "Screenshot", fit: fit,
                                action: toggles.takeScreenshot)
                    ControlTile(symbol: "moon.zzz.fill", title: "Sleep", state: "Display", fit: fit, action: toggles.sleepDisplay)
                }
            }
        }
    }
}

private extension ControlToggleGrid {
    /// "Until 5:30 PM", "On" or "Off".
    var awakeState: String {
        guard toggles.isKeepingAwake else { return "Off" }
        return toggles.keepAwakeEnd.map { "Until \($0.formatted(date: .omitted, time: .shortened))" } ?? "On"
    }
}

/// How long to keep the Mac awake, from the tile's right-click menu.
private struct KeepAwakeMenu: View {
    private let lengths: [(title: String, minutes: Int)] = [("30 Minutes", 30), ("1 Hour", 60), ("2 Hours", 120), ("4 Hours", 240)]

    var body: some View {
        let toggles = QuickToggles.shared
        ForEach(lengths, id: \.minutes) { length in
            Button(length.title) { toggles.keepAwake(until: .now.addingTimeInterval(TimeInterval(length.minutes * 60))) }
        }
        Button("Until Turned Off") { toggles.keepAwake() }
        if toggles.isKeepingAwake {
            Divider()
            Button("Turn Off") { toggles.stopKeepingAwake() }
        }
    }
}

/// A pane of glass standing on the slab: a symbol at the top, its name and state at the bottom.
/// One that's on is the accent's lens, with its words in ink.
private struct ControlTile: View {
    /// How a tile fits its room: a short one leaves out the state, a narrow one pulls its padding in.
    struct Fit {
        let showsState: Bool
        let padding: CGFloat

        init(width: CGFloat, height: CGFloat) {
            showsState = height >= 68
            padding = width < 68 || height < 56 ? 7 : 9
        }
    }

    let symbol: String
    let title: String
    let state: String
    var isOn = false
    let fit: Fit
    let action: () -> Void
    @Environment(\.notchTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @ViewState private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                Spacer(minLength: 2)
                // Each line keeps its full height (SwiftUI sets these sizes 14 and 13 points tall)
                // when it shrinks to fit, so a long state like "Screenshot" doesn't drop its title
                // below its neighbours'.
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(height: 14, alignment: .bottomLeading)
                if fit.showsState {
                    Text(state)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isOn ? theme.onAccent.opacity(0.8) : theme.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(height: 13, alignment: .bottomLeading)
                }
            }
            .foregroundStyle(isOn ? theme.onAccent : theme.primary)
            .padding(fit.padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .glass(isOn ? .lens(theme.accent) : .pane, in: shape, isLit: hovering)
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.95))
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .animation(.notchToggle, value: isOn)
        .help("\(title): \(state)")
        .accessibilityLabel(title)
        .accessibilityValue(state)
    }
}
