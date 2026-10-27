import SwiftUI

struct PomodoroWidget: View {
    /// The compact version fits next to the media player on the Nook tab.
    var compact: Bool
    @ObservedObject private var timer = PomodoroTimer.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        // On the Focus tab it sits beside the named timers, so it goes by its own name there.
        WidgetCard(title: compact ? nil : "Pomodoro", symbol: "timer") {
            VStack(spacing: 4) {
                ZStack {
                    ProgressRing(progress: timer.progress, color: timer.phase.color, lineWidth: 5)
                    VStack(spacing: 1) {
                        Text(Format.duration(timer.remaining))
                            .font(NotchFont.numeric(compact ? 18 : 17))
                            .contentTransition(.numericText(countsDown: true))
                        Text(timer.phase.title)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(timer.phase.color)
                            .lineLimit(1)
                        // The round's sessions, inside the ring so the title has room.
                        if !compact {
                            sessionDots
                                .padding(.top, 3)
                        }
                    }
                }
                .frame(width: compact ? 80 : 72, height: compact ? 80 : 72)
                .animation(.linear(duration: 0.5), value: timer.remaining)

                HStack(spacing: 2) {
                    IconButton(symbol: "arrow.counterclockwise", size: 11, help: "Reset", action: timer.reset)
                    IconButton(symbol: timer.isRunning ? "pause.fill" : "play.fill", size: 15,
                               isActive: true, activeColor: timer.phase.color,
                               help: timer.isRunning ? "Pause" : "Start", action: timer.toggle)
                        .contentTransition(.symbolEffect(.replace))
                    IconButton(symbol: "forward.end.fill", size: 11, help: "Skip to the next phase", action: timer.skip)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sessionDots: some View {
        // Smaller dots for long rounds, so they fit inside the ring.
        let dense = settings.sessionsPerRound > 5
        return HStack(spacing: dense ? 2 : 3) {
            ForEach(0..<max(1, settings.sessionsPerRound), id: \.self) { index in
                Circle()
                    .fill(index < timer.completedSessions ? PomodoroTimer.Phase.focus.color : Color.white.opacity(0.22))
                    .frame(width: dense ? 3.5 : 4, height: dense ? 3.5 : 4)
            }
        }
        .help("Focus sessions this round")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(timer.completedSessions) of \(settings.sessionsPerRound) focus sessions this round")
    }
}
