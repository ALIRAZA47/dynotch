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

struct QuickTogglesWidget: View {
    var compact: Bool
    @ObservedObject private var toggles = QuickToggles.shared
    @ObservedObject private var volume = VolumeMonitor.shared

    var body: some View {
        WidgetCard(title: compact ? nil : "Quick toggles", symbol: "switch.2") {
            Grid(horizontalSpacing: 6, verticalSpacing: compact ? 6 : 8) {
                GridRow {
                    ToggleTile(symbol: toggles.isDarkMode ? "moon.fill" : "sun.max.fill", title: "Dark",
                               isOn: toggles.isDarkMode, tint: .indigo, action: toggles.toggleDarkMode)
                    ToggleTile(symbol: "cup.and.saucer.fill", title: "Awake",
                               isOn: toggles.isKeepingAwake, tint: .orange, action: toggles.toggleKeepAwake)
                    ToggleTile(symbol: volume.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", title: "Mute",
                               isOn: volume.isMuted, tint: .red) { volume.setMuted(!volume.isMuted) }
                }
                GridRow {
                    ToggleTile(symbol: "eyedropper", title: "Color", isOn: false, tint: .teal, action: toggles.pickColor)
                    ToggleTile(symbol: "camera.viewfinder", title: "Capture", isOn: false, tint: .white, action: toggles.takeScreenshot)
                    ToggleTile(symbol: "moon.zzz.fill", title: "Sleep", isOn: false, tint: .white, action: toggles.sleepDisplay)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ToggleTile: View {
    let symbol: String
    let title: String
    let isOn: Bool
    let tint: Color
    let action: () -> Void
    @Environment(\.notchTheme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isOn ? Color.black : theme.primary.opacity(0.9))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(isOn ? AnyShapeStyle(tint) : AnyShapeStyle(hovering ? theme.controlHover : theme.control)))
                    .overlay(Circle().strokeBorder(theme.primary.opacity(isOn ? 0 : 0.06)))
                    .contentTransition(.symbolEffect(.replace))
                Text(title)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(hovering || isOn ? theme.primary.opacity(0.85) : theme.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .animation(.easeOut(duration: 0.15), value: isOn)
    }
}
