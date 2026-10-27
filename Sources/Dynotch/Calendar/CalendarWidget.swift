import SwiftUI

/// A five-day strip and the selected day's events.
struct CalendarWidget: View {
    @ObservedObject private var calendar = CalendarService.shared
    @ViewState private var selectedDay = Calendar.current.startOfDay(for: .now)
    @Environment(\.notchTheme) private var theme

    private static let moreHeight: CGFloat = 12

    var body: some View {
        if calendar.hasEventAccess {
            WidgetCard {
                VStack(alignment: .leading, spacing: NotchTheme.titleGap) {
                    // The month and the day in full when they fit, shorter when they don't.
                    ViewThatFits(in: .horizontal) {
                        title(month: .wide, weekday: .wide)
                        title(month: .abbreviated, weekday: .wide)
                        title(month: .abbreviated, weekday: .abbreviated)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        dayStrip
                        eventList
                    }
                }
            }
        } else {
            WidgetCard(title: "Calendar", symbol: "calendar") {
                PermissionPrompt(symbol: "calendar", message: "See what's next without leaving your work.",
                                 buttonTitle: "Allow Calendar", action: calendar.requestEventAccess)
            }
        }
    }

    /// The selected day's month, and which day it is on the right.
    private func title(month: Date.FormatStyle.Symbol.Month, weekday: Date.FormatStyle.Symbol.Weekday) -> some View {
        CardTitle(title: selectedDay.formatted(.dateTime.month(month)), symbol: "calendar") {
            Text(dayName(selectedDay, weekday: weekday).uppercased())
                .tracking(0.6)
                .foregroundStyle(Calendar.current.isDateInToday(selectedDay) ? theme.accent : theme.tertiary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    /// "Today", "Tomorrow" or the day of the week.
    private func dayName(_ day: Date, weekday: Date.FormatStyle.Symbol.Weekday) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow" }
        return day.formatted(.dateTime.weekday(weekday))
    }

    private var dayStrip: some View {
        let today = Calendar.current.startOfDay(for: .now)
        let days = (0..<5).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: today) }
        return HStack(spacing: 2) {
            ForEach(days, id: \.self) { day in
                DayButton(day: day, isSelected: Calendar.current.isDate(day, inSameDayAs: selectedDay), isToday: day == today,
                          hasEvents: !calendar.events(on: day).isEmpty) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { selectedDay = day }
                }
            }
        }
    }

    @ViewBuilder
    private var eventList: some View {
        let events = calendar.events(on: selectedDay)
        if events.isEmpty {
            EmptyState(symbol: "calendar.badge.checkmark", message: "No events")
        } else {
            // As many rows as fit, then a line that says how many more there are.
            GeometryReader { proxy in
                let row = EventRow.height + EventRow.spacing
                let fitting = max(1, Int((proxy.size.height + EventRow.spacing) / row))
                let shown = events.count <= fitting ? events.count : max(1, Int((proxy.size.height - Self.moreHeight) / row))
                VStack(alignment: .leading, spacing: EventRow.spacing) {
                    ForEach(events.prefix(shown)) { event in
                        EventRow(event: event)
                    }
                    if shown < events.count {
                        Text("+\(events.count - shown) more")
                            .font(NotchFont.caption)
                            .foregroundStyle(theme.tertiary)
                            .frame(height: Self.moreHeight)
                            .padding(.leading, 9)
                    }
                }
            }
        }
    }
}

/// A day in the strip: its initial, its date and a dot when it has events.
private struct DayButton: View {
    let day: Date
    let isSelected: Bool
    let isToday: Bool
    let hasEvents: Bool
    let action: () -> Void
    @Environment(\.notchTheme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(day.formatted(.dateTime.weekday(.narrow)))
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(isSelected ? theme.secondary : theme.tertiary)
                Text(day.formatted(.dateTime.day()))
                    .font(NotchFont.numeric(12))
                    .foregroundStyle(isToday && !isSelected ? theme.accent : theme.primary)
                Circle()
                    .fill(hasEvents ? (isToday ? theme.accent : theme.secondary) : .clear)
                    .frame(width: 3, height: 3)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
                .fill(isSelected ? theme.selection : hovering ? theme.control : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.94))
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month(.wide).day()))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct EventRow: View {
    let event: CalendarService.Event
    @Environment(\.notchTheme) private var theme

    static let height: CGFloat = 26
    static let spacing: CGFloat = 3

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 6) {
                Capsule()
                    .fill(event.color)
                    .frame(width: 3)
                    .padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 0) {
                    Text(event.title)
                        .font(NotchFont.bodyStrong)
                        .lineLimit(1)
                    Text(subtitle(at: context.date))
                        .font(NotchFont.caption)
                        .foregroundStyle(event.isHappening(at: context.date) ? event.color : theme.tertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let url = event.meetingURL, event.end > context.date, event.start.timeIntervalSince(context.date) < 15 * 60 {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Image(systemName: "video.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color.green))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .help("Join")
                }
            }
            .frame(height: Self.height)
            .help(event.title)
        }
    }

    private func subtitle(at now: Date) -> String {
        if event.isAllDay { return "All day" }
        if event.isHappening(at: now) { return "Now · until \(event.end.formatted(date: .omitted, time: .shortened))" }
        if event.start > now, event.start.timeIntervalSince(now) < 3 * 3600 { return Format.countdown(to: event.start, from: now) }
        return event.start.formatted(date: .omitted, time: .shortened)
    }
}
