import SwiftUI

/// The Pomodoro in a card of its own, for the stack beside the player: the dial, then the phase,
/// where the round is and the controls.
struct PomodoroWidget: View {
    @ObservedObject private var timer = PomodoroTimer.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.notchTheme) private var theme

    var body: some View {
        WidgetCard {
            HStack(spacing: 14) {
                PomodoroDial(side: 92)
                VStack(alignment: .leading, spacing: 2) {
                    Text(timer.phase.title)
                        .font(NotchFont.title)
                        .foregroundStyle(timer.phase.color)
                    Text("Session \(min(timer.completedSessions + 1, settings.sessionsPerRound)) of \(settings.sessionsPerRound)")
                        .font(NotchFont.body)
                        .foregroundStyle(theme.secondary)
                    PomodoroControls()
                        .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The Pomodoro's ring, with the time left, the phase and the round's sessions inside it.
struct PomodoroDial: View {
    var side: CGFloat
    @ObservedObject private var timer = PomodoroTimer.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        let large = side >= 100
        ZStack {
            ProgressRing(progress: timer.progress, color: timer.phase.color, lineWidth: large ? 7 : 5)
            VStack(spacing: 1) {
                Text(Format.duration(timer.remaining))
                    .font(NotchFont.numeric(large ? 26 : 19))
                    .contentTransition(.numericText(countsDown: true))
                Text(timer.phase.title)
                    .font(.system(size: large ? 10.5 : 9.5, weight: .semibold))
                    .foregroundStyle(timer.phase.color)
                    .lineLimit(1)
                sessionDots(large: large)
                    .padding(.top, large ? 5 : 3)
            }
        }
        .frame(width: side, height: side)
        .animation(.linear(duration: 0.5), value: timer.remaining)
    }

    private func sessionDots(large: Bool) -> some View {
        // Smaller dots for long rounds, so they fit inside the ring.
        let dense = settings.sessionsPerRound > 5
        let dot: CGFloat = dense ? 3.5 : large ? 5 : 4
        return HStack(spacing: dense ? 2 : large ? 4 : 3) {
            ForEach(0..<max(1, settings.sessionsPerRound), id: \.self) { index in
                Circle()
                    .fill(index < timer.completedSessions ? PomodoroTimer.Phase.focus.color : Color.white.opacity(0.25))
                    .frame(width: dot, height: dot)
            }
        }
        .help("Focus sessions this round")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(timer.completedSessions) of \(settings.sessionsPerRound) focus sessions this round")
    }
}

/// Reset, start or pause in the phase's color, and skip.
struct PomodoroControls: View {
    @ObservedObject private var timer = PomodoroTimer.shared
    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            IconButton(symbol: "arrow.counterclockwise", size: 11, idleOpacity: 0.55, help: "Reset", action: timer.reset)
            Button(action: timer.toggle) {
                Image(systemName: timer.isRunning ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(timer.phase.color)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(timer.phase.color.opacity(hovering ? 0.3 : 0.22)))
                    .contentShape(Circle())
            }
            .buttonStyle(PressableButtonStyle())
            .onHover { hovering = $0 }
            .animation(.notchHighlight, value: hovering)
            .help(timer.isRunning ? "Pause" : "Start")
            .accessibilityLabel(timer.isRunning ? "Pause" : "Start")
            IconButton(symbol: "forward.end.fill", size: 11, idleOpacity: 0.55, help: "Skip to the next phase", action: timer.skip)
        }
    }
}
