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

/// The Pomodoro's ring of light, with the time left, the phase and the round's sessions inside it.
/// A large dial has a minute's tick for each of its sixty, just inside the ring, like a watch's bezel.
struct PomodoroDial: View {
    var side: CGFloat
    @ObservedObject private var timer = PomodoroTimer.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.notchTheme) private var theme

    var body: some View {
        let large = side >= 100
        let lineWidth: CGFloat = large ? 7 : 5
        ZStack {
            if large {
                MinuteTicks(inset: lineWidth / 2 + 1.5)
            }
            ProgressRing(progress: timer.progress, color: timer.phase.color, lineWidth: lineWidth, halo: true)
            VStack(spacing: 1) {
                Text(Format.duration(timer.remaining))
                    .font(NotchFont.figure(large ? 27 : 19))
                    .foregroundStyle(theme.primary)
                    .contentTransition(.numericText(countsDown: true))
                    // On one line, clear of the ticks, however long the session.
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: side - (large ? 34 : 14))
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
                    .fill(index < timer.completedSessions ? PomodoroTimer.Phase.focus.color : Color.white.opacity(0.38))
                    .frame(width: dot, height: dot)
            }
        }
        .help("Focus sessions this round")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(timer.completedSessions) of \(settings.sessionsPerRound) focus sessions this round")
    }
}

/// Sixty ticks round the inside of a dial, one a minute, every fifth longer and brighter. They're
/// printed once and never move: only the ring over them runs.
private struct MinuteTicks: View {
    /// How far in from the dial's edge the ticks begin.
    var inset: CGFloat

    var body: some View {
        ZStack {
            Ticks(inset: inset, length: 3, every: 1, skipping: 5)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
            Ticks(inset: inset, length: 5, every: 5)
                .stroke(Color.white.opacity(0.24), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Every `every`th of sixty marks from twelve o'clock, leaving out every `skipping`th: each
    /// `length` long, reaching in from `inset` inside the edge.
    private struct Ticks: Shape {
        var inset: CGFloat
        var length: CGFloat
        var every: Int
        var skipping: Int?

        func path(in rect: CGRect) -> Path {
            var path = Path()
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let outer = min(rect.width, rect.height) / 2 - inset
            let inner = outer - length
            for minute in stride(from: 0, to: 60, by: every) where skipping.map({ minute % $0 != 0 }) ?? true {
                let angle = Double(minute) / 60 * 2 * .pi - .pi / 2
                let (dx, dy) = (cos(angle), sin(angle))
                path.move(to: CGPoint(x: center.x + dx * inner, y: center.y + dy * inner))
                path.addLine(to: CGPoint(x: center.x + dx * outer, y: center.y + dy * outer))
            }
            return path
        }
    }
}

/// Reset, start or pause on a disc of glass with the phase's light in it, and skip.
struct PomodoroControls: View {
    @ObservedObject private var timer = PomodoroTimer.shared
    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            IconButton(symbol: "arrow.counterclockwise", size: 11, idleOpacity: 0.55, help: "Reset", action: timer.reset)
            Button(action: timer.toggle) {
                Image(systemName: timer.isRunning ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(timer.phase.color)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 34, height: 34)
                    .glass(.tint(timer.phase.color), in: Circle(), isLit: hovering)
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
