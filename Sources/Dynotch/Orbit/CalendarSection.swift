import AppKit
import SwiftUI

/// Calendar: the next event as the one card, with Join while it has a call, and the rest of the day
/// as rows under it, each with its calendar's color as a thin bar. Asks for the calendar first.
struct CalendarSection: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var calendar = CalendarService.shared

    var body: some View {
        Group {
            if calendar.hasEventAccess {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    CalendarDay(agenda: Agenda(calendar: calendar, now: context.date), now: context.date)
                }
            } else {
                PermissionPrompt(symbol: "calendar", message: "See what's next without leaving your work.",
                                 buttonTitle: "Allow Calendar", action: calendar.requestEventAccess)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .orbitHeader("Calendar", subtitle: subtitle) {
            OrbitButton(title: "New event", help: "A name, then the day and the time: cal dentist fri 3pm") {
                viewModel.beginCommand("cal ")
            }
        }
    }

    /// "Thu 26 Nov · 4 events": short, as the band beside the camera is.
    private var subtitle: String {
        let day = Date.now.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        guard calendar.hasEventAccess else { return day }
        let count = calendar.events(on: .now).count
        return day + " · " + (count == 0 ? "No events" : count == 1 ? "1 event" : "\(count) events")
    }

    /// Calendar.app, for Open and Open in Calendar.
    static func openCalendar() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
    }

    /// The call service, from its link.
    static func service(for url: URL) -> String? {
        let host = url.host()?.lowercased() ?? ""
        if host.hasSuffix("zoom.us") { return "Zoom" }
        if host == "meet.google.com" { return "Google Meet" }
        if host.hasSuffix("teams.microsoft.com") || host.hasSuffix("teams.live.com") { return "Teams" }
        if host.hasSuffix("webex.com") { return "Webex" }
        if url.scheme == "facetime" || host == "facetime.apple.com" { return "FaceTime" }
        return nil
    }

    /// Where it is: its place, unless that's only the call's link, then the call service.
    static func place(of event: CalendarService.Event) -> String? {
        if let location = event.location, !location.contains("://") { return location }
        return event.meetingURL.flatMap(service(for:)) ?? (event.meetingURL == nil ? nil : "Video call")
    }

    /// Is the clock 12-hour, so "10:05 PM" needs a wider column?
    static var usesTwelveHourClock: Bool {
        (DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "").contains("a")
    }
}

/// The up-next card and the rest of the day.
private struct CalendarDay: View {
    let agenda: Agenda
    let now: Date
    @Environment(\.notchTheme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            UpNextPanel(agenda: agenda, now: now)
            if !agenda.later.isEmpty {
                Scroller(.vertical, fadesOverflow: true) {
                    VStack(spacing: 0) {
                        ForEach(Array(agenda.later.enumerated()), id: \.element.id) { index, event in
                            if index > 0 { OrbitRowDivider() }
                            row(event)
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                Spacer(minLength: 0)
            }
        }
    }

    private func row(_ event: CalendarService.Event) -> some View {
        var actions = [RowAction(title: "Open", perform: CalendarSection.openCalendar)]
        if let url = event.meetingURL {
            actions.append(RowAction(title: "Join", role: .primary) { NSWorkspace.shared.open(url) })
        }
        let until = event.isAllDay ? nil : "Until " + event.end.formatted(date: .omitted, time: .shortened)
        let subtitle = [until, CalendarSection.place(of: event)].compactMap { $0 }.joined(separator: " · ")
        return OrbitRow(
            id: "event-\(event.id)",
            time: event.isAllDay ? "All day" : event.start.formatted(date: .omitted, time: .shortened),
            timeWidth: CalendarSection.usesTwelveHourClock ? 76 : 62, mark: event.color,
            title: event.title, subtitle: subtitle.isEmpty ? nil : subtitle,
            needsYou: event.isHappening(at: now) && !event.isAllDay,
            actions: actions)
            .help(event.title)
    }
}

/// The next event in full: when it is in small capitals, its title, its times and where, then Open in
/// Calendar and Join. Join always shows here.
private struct UpNextPanel: View {
    let agenda: Agenda
    let now: Date
    @Environment(\.notchTheme) private var theme

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Text(caption)
                    .font(NotchFont.label)
                    .tracking(0.66)
                    .foregroundStyle(theme.accentText)
                    .lineLimit(1)
                Text(agenda.event?.title ?? "Nothing else today")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(agenda.event == nil ? theme.secondary : theme.primary)
                    .lineLimit(1)
                    .padding(.top, 4)
                    .help(agenda.event?.title ?? "")
                if let event = agenda.event {
                    details(event)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            OrbitButton(title: "Open in Calendar", action: CalendarSection.openCalendar)
            if let url = agenda.event?.meetingURL {
                PillButton(title: "Join", height: 36) { NSWorkspace.shared.open(url) }
                    .help(url.absoluteString)
            }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .background(CardSurface())
        .accessibilityElement(children: .contain)
    }

    private func details(_ event: CalendarService.Event) -> some View {
        let times = event.isAllDay ? "All day" : event.start.formatted(date: .omitted, time: .shortened)
            + "–" + event.end.formatted(date: .omitted, time: .shortened)
        let place = CalendarSection.place(of: event).map { " · " + $0 } ?? ""
        return (Text(times).font(NotchFont.time(12.5, .medium)) + Text(place).font(NotchFont.subheadline))
            .foregroundStyle(theme.secondary)
            .lineLimit(1)
    }

    /// "UP NEXT · IN 12 MIN", "NOW · UNTIL 10:45", "TOMORROW · 9:00", "TODAY".
    private var caption: String {
        guard let event = agenda.event else { return "TODAY" }
        let text: String = switch agenda.moment {
        case .now: "Now · until " + event.end.formatted(date: .omitted, time: .shortened)
        case .next: "Up next · " + Format.countdown(to: event.start, from: now)
        case .tomorrow: "Tomorrow · " + event.start.formatted(date: .omitted, time: .shortened)
        case .clear: "Today"
        }
        return text.uppercased()
    }
}
