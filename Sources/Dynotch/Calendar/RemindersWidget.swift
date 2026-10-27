import SwiftUI

/// Open reminders: tick them off or add a new one.
struct RemindersWidget: View {
    @ObservedObject private var calendar = CalendarService.shared
    @ViewState private var draft = ""
    @ViewState private var completing: Set<String> = []
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        WidgetCard(title: "Reminders", symbol: "checklist") {
            if calendar.hasReminderAccess && !calendar.reminders.isEmpty {
                Text("\(calendar.reminders.count)")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
            }
        } content: {
            if calendar.hasReminderAccess {
                VStack(alignment: .leading, spacing: 6) {
                    if calendar.reminders.isEmpty {
                        Text("All done 🎉")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.notchTertiary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Scroller(.vertical) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(calendar.reminders) { reminder in
                                    row(reminder)
                                }
                            }
                        }
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.notchTertiary)
                        if isSnapshot {
                            Text("New reminder")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Color.notchTertiary)
                        } else {
                            TextField("New reminder", text: $draft)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11.5))
                                .onSubmit {
                                    calendar.addReminder(titled: draft)
                                    draft = ""
                                }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.07)))
                }
            } else {
                PermissionPrompt(symbol: "checklist", message: "Check off your reminders from the notch.",
                                 buttonTitle: "Allow Reminders", action: calendar.requestReminderAccess)
            }
        }
    }

    private func row(_ reminder: CalendarService.Reminder) -> some View {
        let done = completing.contains(reminder.id)
        return HStack(alignment: .top, spacing: 7) {
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
                    .foregroundStyle(done ? reminder.color : Color.white.opacity(0.45))
            }
            .buttonStyle(PressableButtonStyle())
            VStack(alignment: .leading, spacing: 0) {
                Text(reminder.title)
                    .font(.system(size: 11.5))
                    .strikethrough(done)
                    .foregroundStyle(done ? Color.notchTertiary : Color.white)
                    .lineLimit(2)
                if let due = reminder.dueDate {
                    Text(dueText(due))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(due < .now ? Color.red : Color.notchTertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func dueText(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        if date < .now { return "Overdue · " + date.formatted(.dateTime.month(.abbreviated).day()) }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}
