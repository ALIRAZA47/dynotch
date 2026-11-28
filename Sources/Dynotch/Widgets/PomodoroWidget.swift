import SwiftUI

/// The Pomodoro in a card of its own, for the Widgets stack: where the round is, the time left as one
/// figure, how far through the round it is, and the controls.
struct PomodoroWidget: View {
    var body: some View {
        WidgetCard {
            VStack(alignment: .leading, spacing: 0) {
                PomodoroFace(figureSize: 34, spacing: 6)
                Spacer(minLength: 8)
                PomodoroControls(isCompact: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// The Pomodoro as Orbit draws it: the round and the phase in small capitals, the time left as one
/// large SF Mono figure, and a segment for each focus session of the round, the one under way filling
/// in the accent.
struct PomodoroFace: View {
    var figureSize: CGFloat = 56
    var spacing: CGFloat = 10
    @ObservedObject private var timer = PomodoroTimer.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.notchTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Self.caption(phase: timer.phase, completed: timer.completedSessions, sessions: settings.sessionsPerRound))
                .font(NotchFont.label)
                .tracking(0.66)
                .foregroundStyle(theme.accentText)
                .lineLimit(1)
            Text(Format.duration(timer.remaining))
                .font(.system(size: figureSize, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .tracking(-figureSize * 0.03)
                .foregroundStyle(theme.primary)
                .contentTransition(.numericText(countsDown: true))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, spacing)
                .accessibilityLabel("\(TimerText.describe(timer.remaining.rounded(.up))) left")
            RoundSegments(sessions: settings.sessionsPerRound, completed: timer.completedSessions,
                          progress: timer.phase == .focus ? timer.progress : 0)
                .padding(.top, spacing + 4)
        }
        .animation(.linear(duration: 0.5), value: timer.remaining)
    }

    /// "ROUND 2 OF 4 · FOCUS", "SHORT BREAK · 2 OF 4 DONE", "LONG BREAK · ROUND DONE".
    static func caption(phase: PomodoroTimer.Phase, completed: Int, sessions: Int) -> String {
        let sessions = max(1, sessions)
        let text: String = switch phase {
        case .focus: "Round \(min(completed + 1, sessions)) of \(sessions) · focus"
        case .shortBreak: "Short break · \(min(completed, sessions)) of \(sessions) done"
        case .longBreak: "Long break · round done"
        }
        return text.uppercased()
    }
}

/// A segment for each focus session of the round: done in the text color, the one under way filling
/// in the accent, the rest empty.
struct RoundSegments: View {
    let sessions: Int
    let completed: Int
    /// How far through the session under way, 0 to 1.
    let progress: Double
    @Environment(\.notchTheme) private var theme

    var body: some View {
        let count = max(1, sessions)
        HStack(spacing: count > 6 ? 2 : 4) {
            ForEach(0..<count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(index < completed ? theme.primary : theme.hover)
                    .overlay(alignment: .leading) {
                        if index == completed, progress > 0 {
                            GeometryReader { proxy in
                                RoundedRectangle(cornerRadius: 1, style: .continuous)
                                    .fill(theme.accent)
                                    .frame(width: proxy.size.width * min(1, progress))
                            }
                        }
                    }
            }
        }
        .frame(height: 5)
        .help("Focus sessions this round")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(min(completed, count)) of \(count) focus sessions this round")
    }
}

/// Start or pause as the focus button, then Reset and Skip.
struct PomodoroControls: View {
    /// Reset and Skip as symbols, for a narrow card.
    var isCompact = false
    @ObservedObject private var timer = PomodoroTimer.shared

    var body: some View {
        HStack(spacing: 6) {
            PillButton(title: runTitle, height: isCompact ? 26 : 28, action: timer.toggle)
                .help(timer.isRunning ? "Pause" : "Start")
                .accessibilityLabel(timer.isRunning ? "Pause" : "Start")
            if isCompact {
                OrbitButton(symbol: "arrow.counterclockwise", help: "Reset", action: timer.reset)
                OrbitButton(symbol: "forward.end.fill", style: .ghost, help: "Skip to the next phase", action: timer.skip)
            } else {
                OrbitButton(title: "Reset", height: 28, help: "Reset", action: timer.reset)
                OrbitButton(title: "Skip", style: .ghost, height: 28, help: "Skip to the next phase", action: timer.skip)
            }
        }
    }

    /// Start at the beginning of a phase, Resume part way through it, Pause while it runs.
    private var runTitle: String {
        if timer.isRunning { return "Pause" }
        return timer.progress > 0 ? "Resume" : "Start"
    }
}
