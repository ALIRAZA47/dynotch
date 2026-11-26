import SwiftUI

/// Focus: the Pomodoro as one large figure, with this week's focus beside it when there's room, and
/// beside that the named timers, the stopwatch and the open reminders as rows.
struct FocusSection: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var history = FocusHistory.shared
    @ObservedObject private var focus = FocusMonitor.shared

    var body: some View {
        GeometryReader { proxy in
            HStack(alignment: .top, spacing: NotchTheme.gap) {
                PomodoroCard()
                    .frame(width: (proxy.size.width * 0.47).rounded())
                Scroller(.vertical, fadesOverflow: true) {
                    VStack(spacing: 0) {
                        TimerRows()
                        FocusReminders { viewModel.beginCommand("remind ") }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .orbitHeader("Focus", subtitle: subtitle) {
            if let mode = focus.mode {
                FocusModeChip(mode: mode)
            }
            OrbitButton(title: "New timer", help: "A name and a time: tea 4m, eggs 90s, nap 1h30") {
                viewModel.beginCommand("timer ")
            }
        }
    }

    /// "Today 3 sessions · 1 h 15 min", or how the week's going before the day's first.
    private var subtitle: String {
        let summary = history.summary()
        if summary.sessionsToday > 0 {
            return "Today \(summary.sessionsToday) \(summary.sessionsToday == 1 ? "session" : "sessions") · "
                + TimerText.describe(TimeInterval(summary.minutesToday * 60))
        }
        if summary.sessionsThisWeek > 0 {
            return "This week \(summary.sessionsThisWeek) \(summary.sessionsThisWeek == 1 ? "session" : "sessions")"
        }
        return "No sessions yet today"
    }
}

/// The Pomodoro's card: the face, this week's bars beside the figure when they fit, and the
/// controls at its foot.
private struct PomodoroCard: View {
    @ObservedObject private var history = FocusHistory.shared
    @Environment(\.notchTheme) private var theme

    var body: some View {
        let hasWeek = history.summary().sessionsThisWeek > 0
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                if proxy.size.height >= 330 {
                    // A tall panel: a larger figure, and the week under it at full size.
                    PomodoroFace(figureSize: 72)
                    if hasWeek {
                        Spacer(minLength: 12)
                        FocusStrip(barHeight: 48)
                    }
                } else if hasWeek {
                    // The bars give way to a long figure, like an hour-long session's.
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            PomodoroFace().fixedSize()
                            Spacer(minLength: 0)
                            FocusStrip(barHeight: 42, barWidth: 9, title: "THIS WEEK")
                        }
                        PomodoroFace()
                    }
                } else {
                    PomodoroFace()
                }
                Spacer(minLength: 14)
                PomodoroControls()
            }
            .padding(16)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .background(CardSurface())
    }
}

/// The open reminders under a small heading: tick one off from its row, or add one from the command
/// field. Asks for Reminders first.
private struct FocusReminders: View {
    var onNewReminder: () -> Void
    @ObservedObject private var calendar = CalendarService.shared
    @Environment(\.notchTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(heading)
                    .font(NotchFont.label)
                    .tracking(0.66)
                    .foregroundStyle(theme.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if calendar.hasReminderAccess {
                    OrbitButton(symbol: "plus", style: .ghost, height: 22, help: "New reminder", action: onNewReminder)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 4)
            if !calendar.hasReminderAccess {
                prompt
            } else if calendar.reminders.isEmpty {
                Text("All done")
                    .font(NotchFont.subheadline)
                    .foregroundStyle(theme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(calendar.reminders.enumerated()), id: \.element.id) { index, reminder in
                    if index > 0 { OrbitRowDivider() }
                    row(reminder)
                }
            }
        }
    }

    private var heading: String {
        guard calendar.hasReminderAccess, !calendar.reminders.isEmpty else { return "REMINDERS" }
        return "REMINDERS · \(calendar.reminders.count)"
    }

    private var prompt: some View {
        HStack(spacing: 12) {
            Text("Check off your reminders from the notch.")
                .font(NotchFont.subheadline)
                .foregroundStyle(theme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            PillButton(title: "Allow Reminders", action: calendar.requestReminderAccess)
        }
        .padding(.horizontal, 10)
        .frame(height: NotchTheme.rowHeight)
    }

    private func row(_ reminder: CalendarService.Reminder) -> some View {
        let overdue = reminder.dueDate.map { $0 < .now } ?? false
        return OrbitRow(
            id: "reminder-\(reminder.id)", symbol: "circle", title: reminder.title,
            subtitle: reminder.dueDate.map(Self.dueText), needsYou: overdue,
            actions: [RowAction(title: "Done", symbol: "checkmark") {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { calendar.complete(reminder) }
            }])
            .help(reminder.title)
    }

    /// "Today", "Tomorrow", "Overdue · 25 Nov", "Mon 30 Nov".
    static func dueText(_ date: Date) -> String {
        let calendar = Calendar.current
        if date < .now, !calendar.isDateInToday(date) { return "Overdue · " + date.formatted(.dateTime.month(.abbreviated).day()) }
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

/// The Mac's Focus while one is on, beside the section's buttons.
private struct FocusModeChip: View {
    let mode: FocusMode
    @Environment(\.notchTheme) private var theme

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: mode.symbol)
                .font(.system(size: 11, weight: .semibold))
            Text(mode.name)
                .font(NotchFont.subheadline)
                .lineLimit(1)
        }
        .foregroundStyle(theme.secondary)
        .padding(.horizontal, 8)
        .frame(height: NotchTheme.headerControlHeight)
        .help("\(mode.name) is on")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mode.name) Focus is on")
    }
}
