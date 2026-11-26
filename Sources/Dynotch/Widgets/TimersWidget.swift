import SwiftUI

/// Named timers started from text like "tea 4m", and the stopwatch, as rows: the time left in the
/// time column, and Pause and Cancel where the row actions show. Focus lists them beside the Pomodoro.
struct TimerRows: View {
    @ObservedObject private var store = TimerStore.shared
    @Environment(\.notchTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if store.countdowns.isEmpty {
                emptyRow
            }
            ForEach(store.countdowns) { countdown in
                row(countdown)
                    .transition(reduceMotion ? AnyTransition.opacity : .opacity.combined(with: .move(edge: .top)))
                OrbitRowDivider()
            }
            stopwatchRow
        }
    }

    private func row(_ countdown: Countdown) -> some View {
        let running = countdown.isRunning
        let left = countdown.remaining(at: store.now).rounded(.up)
        let ends = countdown.endDate.map { "Ends at \($0.formatted(date: .omitted, time: .shortened))" }
        return OrbitRow(
            id: "countdown-\(countdown.id)", time: Format.duration(left),
            title: countdown.name.isEmpty ? "Timer" : countdown.name,
            subtitle: ends ?? "Paused · \(TimerText.describe(countdown.duration)) timer",
            status: running ? "Running" : "Paused", statusColor: running ? theme.live : nil,
            actions: [
                RowAction(title: running ? "Pause" : "Resume") { store.togglePause(countdown) },
                RowAction(title: "Cancel") {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { store.cancel(countdown) }
                },
            ])
            .help(countdown.name)
    }

    private var stopwatchRow: some View {
        let stopwatch = store.stopwatch
        var actions: [RowAction] = []
        if !stopwatch.isReset {
            actions.append(RowAction(title: "Reset", perform: store.resetStopwatch))
        }
        actions.append(RowAction(title: stopwatch.isRunning ? "Pause" : stopwatch.isReset ? "Start" : "Resume",
                                 perform: store.toggleStopwatch))
        return OrbitRow(
            id: "stopwatch", time: Format.duration(stopwatch.elapsed(at: store.now)), title: "Stopwatch",
            subtitle: stopwatch.isRunning ? "Counting up" : stopwatch.isReset ? "Ready" : "Paused",
            status: stopwatch.isRunning ? "Running" : stopwatch.isReset ? nil : "Paused",
            statusColor: stopwatch.isRunning ? theme.live : nil,
            actions: actions)
            .help(stopwatch.isRunning ? "Pause the stopwatch" : "Start the stopwatch")
    }

    /// No timers yet: how to start one.
    private var emptyRow: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("No timers running")
                .font(NotchFont.headline)
                .foregroundStyle(theme.primary)
            Text("Type a name and a time, like tea 4m or laundry 45.")
                .font(NotchFont.subheadline)
                .foregroundStyle(theme.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .frame(height: NotchTheme.rowHeight)
        .overlay(alignment: .bottom) { OrbitRowDivider() }
    }
}
