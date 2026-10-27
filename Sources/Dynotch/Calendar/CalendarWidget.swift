import AppKit
import SwiftUI

/// What's next on the calendar: the next event in full, with Join when it has a call link, and the
/// rest of the day underneath. After the day's last event, tomorrow's first.
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
                        Text(when)
                            .font(NotchFont.numeric(11))
                            .foregroundStyle(agenda.isSoon(at: now) ? Color.orange : theme.tertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                if let event = agenda.event {
                    EventDetail(event: event)
                        .padding(.top, 8)
                } else {
                    Text("Nothing else today")
                        .font(NotchFont.title)
                        .foregroundStyle(theme.secondary)
                        .padding(.top, 8)
                }
                Spacer(minLength: 6)
                if !agenda.later.isEmpty {
                    LaterEvents(events: agenda.later)
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
                .font(NotchFont.title)
                .lineLimit(1)
                .help(event.title)
            Text(details)
                .font(NotchFont.body)
                .foregroundStyle(theme.secondary)
                .lineLimit(1)
            HStack(spacing: 6) {
                if let url = event.meetingURL {
                    JoinButton(url: url)
                }
                PillButton(title: "Open in Calendar", tint: .white) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
                }
            }
            .padding(.top, 8)
        }
    }

    private var details: String {
        let times = event.isAllDay ? "All day" : event.start.formatted(date: .omitted, time: .shortened)
            + " – " + event.end.formatted(date: .omitted, time: .shortened)
        guard let service = event.meetingURL.flatMap(Self.service(for:)) else { return times }
        return times + " · " + service
    }

    /// The call service, from its link.
    private static func service(for url: URL) -> String? {
        let host = url.host()?.lowercased() ?? ""
        if host.hasSuffix("zoom.us") { return "Zoom" }
        if host == "meet.google.com" { return "Google Meet" }
        if host.hasSuffix("teams.microsoft.com") || host.hasSuffix("teams.live.com") { return "Teams" }
        if host.hasSuffix("webex.com") { return "Webex" }
        if url.scheme == "facetime" || host == "facetime.apple.com" { return "FaceTime" }
        return nil
    }
}

/// Joins the call, in green like the call buttons in FaceTime.
struct JoinButton: View {
    let url: URL
    var height: CGFloat = 24
    @ViewState private var hovering = false

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
            .background(Capsule().fill(Color(red: 0.19, green: 0.82, blue: 0.35).opacity(hovering ? 1 : 0.92)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.94))
        .onHover { hovering = $0 }
        .help(url.absoluteString)
    }
}

/// The rest of the day under a hairline: as many rows as fit, each its time, calendar color and title.
private struct LaterEvents: View {
    let events: [CalendarService.Event]
    @Environment(\.notchTheme) private var theme

    private static let row: CGFloat = 16
    private static let spacing: CGFloat = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            theme.divider.frame(height: 1)
            GeometryReader { proxy in
                let fitting = max(0, Int((proxy.size.height - 7 + Self.spacing) / (Self.row + Self.spacing)))
                VStack(alignment: .leading, spacing: Self.spacing) {
                    ForEach(events.prefix(fitting)) { event in
                        HStack(spacing: 8) {
                            Text(event.isAllDay ? "All day" : event.start.formatted(date: .omitted, time: .shortened))
                                .font(NotchFont.numeric(10.5))
                                .foregroundStyle(theme.tertiary)
                                .lineLimit(1)
                                .frame(width: 46, alignment: .leading)
                            Capsule()
                                .fill(event.color)
                                .frame(width: 3, height: 11)
                            Text(event.title)
                                .font(NotchFont.body)
                                .lineLimit(1)
                        }
                        .frame(height: Self.row)
                        .help(event.title)
                    }
                }
                .padding(.top, 7)
            }
            .frame(minHeight: Self.row + 7, maxHeight: Self.row * 3 + Self.spacing * 2 + 7)
        }
    }
}
