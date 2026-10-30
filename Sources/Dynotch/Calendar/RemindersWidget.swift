import SwiftUI

/// Open reminders: tick them off or add a new one. One of the two lists in the Focus tab's second card.
struct RemindersList: View {
    @ObservedObject private var calendar = CalendarService.shared
    @ViewState private var draft = ""
    @ViewState private var completing: Set<String> = []
    @Environment(\.notchTheme) private var theme

    var body: some View {
        if calendar.hasReminderAccess {
            VStack(alignment: .leading, spacing: 4) {
                if calendar.reminders.isEmpty {
                    EmptyState(symbol: "checkmark.circle", message: "All done")
                } else {
                    Scroller(.vertical, fadesOverflow: true) {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(calendar.reminders) { reminder in
                                row(reminder)
                            }
                        }
                    }
                    .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
                }
                CardField(placeholder: "New reminder", text: $draft) {
                    calendar.addReminder(titled: draft)
                    draft = ""
                }
            }
        } else {
            PermissionPrompt(symbol: "checklist", message: "Check off your reminders from the notch.",
                             buttonTitle: "Allow Reminders", action: calendar.requestReminderAccess)
        }
    }

    private func row(_ reminder: CalendarService.Reminder) -> some View {
        let done = completing.contains(reminder.id)
        return HStack(alignment: .top, spacing: 6) {
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { _ = completing.insert(reminder.id) }
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    calendar.complete(reminder)
                    completing.remove(reminder.id)
                }
            } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(done ? reminder.color : theme.secondary)
                    .contentTransition(.symbolEffect(.replace))
                    // As tall as the title's first line, so the circle sits beside it.
                    .frame(height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .help("Complete")
            VStack(alignment: .leading, spacing: 0) {
                Text(reminder.title)
                    .font(NotchFont.body)
                    .strikethrough(done)
                    .foregroundStyle(done ? theme.tertiary : theme.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let due = reminder.dueDate {
                Text(dueText(due))
                    .font(NotchFont.caption)
                    .foregroundStyle(due < .now ? theme.overdue : Calendar.current.isDateInToday(due) ? Color.orange : theme.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .help(reminder.title)
    }

    private func dueText(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        if date < .now { return "Overdue · " + date.formatted(.dateTime.month(.abbreviated).day()) }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}
