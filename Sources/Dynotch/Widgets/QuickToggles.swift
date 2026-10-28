import AppKit
import IOKit.pwr_mgt
import SwiftUI

/// One-tap system actions for the Stats tab.
@MainActor
final class QuickToggles: ObservableObject {
    static let shared = QuickToggles()

    @Published private(set) var isDarkMode = QuickToggles.systemIsDark()
    @Published private(set) var isKeepingAwake = false

    private var assertion: IOPMAssertionID = 0
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

    /// Keeps the display awake, like `caffeinate -d`.
    func toggleKeepAwake() {
        if isKeepingAwake {
            IOPMAssertionRelease(assertion)
            isKeepingAwake = false
        } else {
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "Keep Awake from Dynotch" as CFString, &assertion)
            isKeepingAwake = result == kIOReturnSuccess
        }
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
/// screenshot and sleeping the display, which happen once. A tile that's on fills with the accent.
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
                    ControlTile(symbol: "cup.and.saucer.fill", title: "Awake", state: toggles.isKeepingAwake ? "On" : "Off",
                                isOn: toggles.isKeepingAwake, fit: fit, action: toggles.toggleKeepAwake)
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

/// A rounded tile: a symbol at the top, its name and state at the bottom.
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
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if fit.showsState {
                    Text(state)
                        .font(.system(size: 10, weight: .medium))
                        .opacity(isOn ? 0.75 : 0.6)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            .foregroundStyle(isOn ? theme.onAccent : theme.primary)
            .padding(fit.padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(shape.fill(isOn ? AnyShapeStyle(theme.accent) : AnyShapeStyle(hovering ? theme.controlHover : theme.control)))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.95))
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .animation(.easeOut(duration: 0.15), value: isOn)
        .help("\(title): \(state)")
        .accessibilityLabel(title)
        .accessibilityValue(state)
    }
}
