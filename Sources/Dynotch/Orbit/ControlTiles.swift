import SwiftUI

/// Four toggle tiles across the section, as in Control Center: Dark Mode, Keep Awake, the
/// microphone and a focus session. Each is a raised tile with a round symbol that turns the
/// accent while it's on, its name, and what it's set to underneath.
struct ControlTileRow: View {
    let metrics: ControlMetrics
    @ObservedObject private var toggles = QuickToggles.shared
    @ObservedObject private var mic = MicMonitor.shared

    var body: some View {
        HStack(spacing: 8) {
            ControlToggleTile(symbol: "circle.lefthalf.filled", title: "Dark Mode", state: toggles.isDarkMode ? "On" : "Off",
                              isOn: toggles.isDarkMode, metrics: metrics, action: toggles.toggleDarkMode)
            ControlToggleTile(symbol: "cup.and.saucer.fill", title: "Keep Awake", state: awakeState,
                              isOn: toggles.isKeepingAwake, metrics: metrics, action: toggles.toggleKeepAwake)
                .contextMenu { KeepAwakeMenu() }
            ControlToggleTile(symbol: mic.isMuted ? "mic.slash.fill" : "mic.fill", title: "Mute Mic",
                              state: mic.hasInput ? (mic.isMuted ? "Muted" : "Off") : "No mic",
                              isOn: mic.isMuted, metrics: metrics, action: mic.toggleMute)
                .disabled(!mic.hasInput)
            FocusSessionTile(metrics: metrics)
        }
        .frame(height: metrics.tile)
    }

    /// "Until 5:30 PM", "On" or "Off".
    private var awakeState: String {
        guard toggles.isKeepingAwake else { return "Off" }
        return toggles.keepAwakeEnd.map { "Until \($0.formatted(date: .omitted, time: .shortened))" } ?? "On"
    }
}

/// The Focus section's session, started and paused from here. Its own view, so the countdown
/// ticking redraws only this tile.
private struct FocusSessionTile: View {
    let metrics: ControlMetrics
    @ObservedObject private var pomodoro = PomodoroTimer.shared

    var body: some View {
        ControlToggleTile(symbol: pomodoro.phase == .focus ? "timer" : "cup.and.saucer.fill", title: "Focus",
                          state: state, isOn: pomodoro.isRunning, metrics: metrics, action: pomodoro.toggle)
            .help(pomodoro.isRunning ? "Pause the focus timer" : "Start a focus session")
    }

    /// "18:24 left", "Break · 4:12", "Paused · 12:00" or "Off".
    private var state: String {
        let time = Format.duration(pomodoro.remaining)
        let isMidway = pomodoro.remaining > 0 && pomodoro.remaining < pomodoro.duration
        switch (pomodoro.isRunning, pomodoro.phase) {
        case (true, .focus): return "\(time) left"
        case (true, _): return "Break · \(time)"
        case (false, _) where isMidway: return "Paused · \(time)"
        default: return "Off"
        }
    }
}

/// A toggle tile. On, its symbol's disc is the accent with ink on it.
struct ControlToggleTile: View {
    let symbol: String
    let title: String
    let state: String
    let isOn: Bool
    let metrics: ControlMetrics
    let action: () -> Void
    @Environment(\.notchTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ZStack {
                    Circle().fill(isOn ? theme.accent : hovering ? theme.controlHover : theme.hover)
                    Image(systemName: symbol)
                        .font(.system(size: metrics.disc * 0.44, weight: .semibold))
                        .foregroundStyle(isOn ? theme.onAccent : theme.primary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: metrics.disc, height: metrics.disc)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(theme.primary)
                    Text(state)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondary)
                        .monospacedDigit()
                }
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                theme.tileShape.fill(hovering ? theme.hover : theme.raised)
                theme.tileShape.strokeBorder(theme.line, lineWidth: 1)
            }
            .contentShape(theme.tileShape)
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.96))
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .animation(.notchToggle, value: isOn)
        .help("\(title): \(state)")
        .accessibilityLabel(title)
        .accessibilityValue(state)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
