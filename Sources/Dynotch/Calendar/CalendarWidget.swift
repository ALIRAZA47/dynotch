import SwiftUI

/// A five-day strip and the selected day's events.
struct CalendarWidget: View {
    @ObservedObject private var calendar = CalendarService.shared
    @ViewState private var selectedDay = Calendar.current.startOfDay(for: .now)

    var body: some View {
        WidgetCard {
            if calendar.hasEventAccess {
                content
            } else {
                PermissionPrompt(symbol: "calendar", message: "See what's next without leaving your work.",
                                 buttonTitle: "Allow Calendar", action: calendar.requestEventAccess)
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(selectedDay.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.system(size: 13, weight: .bold))
                Spacer(minLength: 0)
                Text(selectedDay.formatted(.dateTime.weekday(.wide)))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.notchTertiary)
            }
            dayStrip
            eventList
        }
    }

    private var dayStrip: some View {
        let today = Calendar.current.startOfDay(for: .now)
        let days = (0..<5).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: today) }
        return HStack(spacing: 2) {
            ForEach(days, id: \.self) { day in
                let isSelected = Calendar.current.isDate(day, inSameDayAs: selectedDay)
                let hasEvents = !calendar.events(on: day).isEmpty
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { selectedDay = day }
                } label: {
                    VStack(spacing: 1) {
                        Text(day.formatted(.dateTime.weekday(.narrow)))
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(Color.notchTertiary)
                        Text(day.formatted(.dateTime.day()))
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(day == today && !isSelected ? Color.red : Color.white)
                        Circle()
                            .fill(hasEvents ? Color.white.opacity(0.6) : .clear)
                            .frame(width: 3, height: 3)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(isSelected ? 0.14 : 0)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var eventList: some View {
        let events = calendar.events(on: selectedDay)
        if events.isEmpty {
            Text("No events")
                .font(.system(size: 11))
                .foregroundStyle(Color.notchTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(events.prefix(3)) { event in
                    EventRow(event: event)
                }
                if events.count > 3 {
                    Text("+\(events.count - 3) more")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.notchTertiary)
                }
            }
        }
    }
}

private struct EventRow: View {
    let event: CalendarService.Event

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 6) {
                Capsule()
                    .fill(event.color)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 0) {
                    Text(event.title)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text(subtitle(at: context.date))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(event.isHappening(at: context.date) ? event.color : Color.notchTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
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
            .frame(height: 24)
        }
    }

    private func subtitle(at now: Date) -> String {
        if event.isAllDay { return "All day" }
        if event.isHappening(at: now) { return "Now · until \(event.end.formatted(date: .omitted, time: .shortened))" }
        if event.start > now, event.start.timeIntervalSince(now) < 3 * 3600 { return Format.countdown(to: event.start, from: now) }
        return event.start.formatted(date: .omitted, time: .shortened)
    }
}
