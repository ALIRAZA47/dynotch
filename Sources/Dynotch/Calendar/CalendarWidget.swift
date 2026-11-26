import AppKit
import SwiftUI

/// What's next on the calendar, as a card for the Widgets stack: the next event in full, with Join
/// when it has a call link, and the rest of the day underneath. After the day's last event,
/// tomorrow's first. The Calendar section shows the same day at full size.
struct CalendarWidget: View {
    @ObservedObject private var calendar = CalendarService.shared

    var body: some View {
        if calendar.hasEventAccess {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                UpNextCard(agenda: Agenda(calendar: calendar, now: context.date), now: context.date)
            }
        } else {
            WidgetCard(title: "Calendar", symbol: "calendar") {
                PermissionPrompt(symbol: "calendar", message: "See what's next without leaving your work.",
                                 buttonTitle: "Allow Calendar", action: calendar.requestEventAccess)
            }
        }
    }
}

/// The day as the card tells it: the event to show in full and what comes after it.
struct Agenda {
    enum Moment { case now, next, tomorrow, clear }

    /// Happening now, starting next, or tomorrow's first once today is done.
    let event: CalendarService.Event?
    let moment: Moment
    /// The rest of today after `event`, all-day events first.
    let later: [CalendarService.Event]

    @MainActor
    init(calendar: CalendarService, now: Date) {
        let today = calendar.events(on: now)
        let timed = today.filter { !$0.isAllDay && $0.end > now }
        let allDay = today.filter(\.isAllDay)
        if let first = timed.first {
            event = first
            moment = first.isHappening(at: now) ? .now : .next
            later = allDay + timed.dropFirst()
        } else if let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now),
                  let first = calendar.events(on: tomorrow).first(where: { !$0.isAllDay }) {
            event = first
            moment = .tomorrow
            later = allDay
        } else {
            event = nil
            moment = .clear
            later = allDay
        }
    }

    /// Soon enough to say so in orange.
    func isSoon(at now: Date) -> Bool {
        guard let event else { return false }
        return moment == .now || (moment == .next && event.start.timeIntervalSince(now) < 15 * 60)
    }
}

private struct UpNextCard: View {
    let agenda: Agenda
    let now: Date
    @Environment(\.notchTheme) private var theme

    var body: some View {
        WidgetCard {
            VStack(alignment: .leading, spacing: 0) {
                CardTitle(title: heading, symbol: "calendar") {
                    if let when {
                        // In the accent while it's soon; as bright as the label otherwise.
                        Text(when)
                            .font(NotchFont.time(11))
                            .foregroundStyle(agenda.isSoon(at: now) ? theme.accentText : theme.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                // A short card, or a long day, scrolls.
                Scroller(.vertical, fadesOverflow: true) {
                    VStack(alignment: .leading, spacing: 10) {
                        if let event = agenda.event {
                            EventDetail(event: event)
                        } else {
                            Text("Nothing else today")
                                .font(NotchFont.headline)
                                .foregroundStyle(theme.secondary)
                        }
                        if !agenda.later.isEmpty {
                            LaterEvents(events: agenda.later)
                        }
                    }
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var heading: String {
        switch agenda.moment {
        case .now: "Now"
        case .next: "Up next"
        case .tomorrow: "Tomorrow"
        case .clear: "Today"
        }
    }

    /// When it ends, how soon it starts, or what time tomorrow.
    private var when: String? {
        guard let event = agenda.event else { return nil }
        switch agenda.moment {
        case .now: return "until " + event.end.formatted(date: .omitted, time: .shortened)
        case .next: return Format.countdown(to: event.start, from: now)
        case .tomorrow: return event.start.formatted(date: .omitted, time: .shortened)
        case .clear: return nil
        }
    }
}

/// The event's title, its times and where the call is, then Join and Open in Calendar.
private struct EventDetail: View {
    let event: CalendarService.Event
    @Environment(\.notchTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(event.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.primary)
                .lineLimit(1)
                .help(event.title)
            Text(details)
                .font(NotchFont.subheadline)
                .foregroundStyle(theme.secondary)
                .lineLimit(1)
            HStack(spacing: 6) {
                if let url = event.meetingURL {
                    PillButton(title: "Join", height: 24) { NSWorkspace.shared.open(url) }
                        .help(url.absoluteString)
                }
                OrbitButton(title: "Open in Calendar", height: 24, action: CalendarSection.openCalendar)
            }
            .padding(.top, 8)
        }
    }

    private var details: String {
        let times = event.isAllDay ? "All day" : event.start.formatted(date: .omitted, time: .shortened)
            + " – " + event.end.formatted(date: .omitted, time: .shortened)
        guard let place = CalendarSection.place(of: event) else { return times }
        return times + " · " + place
    }
}

/// Joins the call, in green like the call buttons in FaceTime: a capsule of green glass, lit from
/// above, with dark ink on it. The glance, on black, keeps it; the open panel uses the focus button.
struct JoinButton: View {
    let url: URL
    var height: CGFloat = 24
    @ViewState private var hovering = false

    /// Join's own green, brightest under the light. It marks the call, so it stays green whatever the accent.
    private static let face = LinearGradient(colors: [Color(red: 0.4, green: 0.92, blue: 0.53), Color(red: 0.15, green: 0.74, blue: 0.32)],
                                             startPoint: .top, endPoint: .bottom)
    private static let rim = LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom)

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "video.fill")
                    .font(.system(size: 9.5, weight: .bold))
                Text("Join")
                    .font(NotchFont.bodyStrong)
            }
            .foregroundStyle(Color(red: 0.02, green: 0.15, blue: 0.06))
            .padding(.horizontal, 11)
            .frame(height: height)
            .background {
                Capsule()
                    .fill(Self.face)
                    .overlay(Capsule().strokeBorder(Self.rim, lineWidth: 1))
                    .brightness(hovering ? 0.05 : 0)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.94))
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .help(url.absoluteString)
    }
}

/// The rest of the day under a hairline, each event its time, calendar color and title.
private struct LaterEvents: View {
    let events: [CalendarService.Event]
    @Environment(\.notchTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            EtchedDivider()
                .padding(.bottom, 2)
            ForEach(events) { event in
                HStack(spacing: 8) {
                    Text(event.isAllDay ? "All day" : event.start.formatted(date: .omitted, time: .shortened))
                        .font(NotchFont.time(10.5, .medium))
                        .foregroundStyle(theme.secondary)
                        .lineLimit(1)
                        // A 12-hour clock's 10:05 PM keeps its PM.
                        .minimumScaleFactor(0.85)
                        .frame(width: 46, alignment: .leading)
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(event.color)
                        .frame(width: 3, height: 12)
                    Text(event.title)
                        .font(NotchFont.body)
                        .foregroundStyle(theme.primary)
                        .lineLimit(1)
                }
                .frame(height: 16)
                .help(event.title)
            }
        }
    }
}
