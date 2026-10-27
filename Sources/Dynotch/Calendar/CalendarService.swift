import AppKit
import EventKit
import SwiftUI

/// Upcoming events and open reminders from EventKit.
@MainActor
final class CalendarService: ObservableObject {
    static let shared = CalendarService()

    struct Event: Identifiable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool
        let color: Color
        let meetingURL: URL?

        func isHappening(at date: Date = .now) -> Bool { start <= date && date < end }
    }

    struct Reminder: Identifiable, Equatable {
        let id: String
        let title: String
        let dueDate: Date?
        let color: Color
    }

    let store = EKEventStore()

    @Published private(set) var eventAccess = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var reminderAccess = EKEventStore.authorizationStatus(for: .reminder)
    /// From the start of today, a week ahead.
    @Published private(set) var events: [Event] = []
    @Published private(set) var reminders: [Reminder] = []

    private var announced: Set<String> = []
    private var loadedDay = Calendar.current.startOfDay(for: .now)
    private var poll: Poll?
    private var observer: NSObjectProtocol?

    private init() {}

    var hasEventAccess: Bool { eventAccess == .fullAccess }
    var hasReminderAccess: Bool { reminderAccess == .fullAccess }

    func start() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
        poll = EnergyCoordinator.shared.schedule(.eventAlerts) { [weak self] in self?.tick() }
    }

    func requestEventAccess() {
        guard eventAccess == .notDetermined else {
            Self.openPrivacySettings("Privacy_Calendars")
            return
        }
        Task {
            _ = try? await store.requestFullAccessToEvents()
            reload()
        }
    }

    func requestReminderAccess() {
        guard reminderAccess == .notDetermined else {
            Self.openPrivacySettings("Privacy_Reminders")
            return
        }
        Task {
            _ = try? await store.requestFullAccessToReminders()
            reload()
        }
    }

    func reload() {
        eventAccess = EKEventStore.authorizationStatus(for: .event)
        reminderAccess = EKEventStore.authorizationStatus(for: .reminder)
        loadedDay = Calendar.current.startOfDay(for: .now)
        if hasEventAccess { loadEvents() }
        if hasReminderAccess { loadReminders() }
    }

    func events(on day: Date) -> [Event] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        return events.filter { $0.start < dayEnd && $0.end > dayStart }
    }

    // MARK: Reminders

    func complete(_ reminder: Reminder) {
        guard let item = store.calendarItem(withIdentifier: reminder.id) as? EKReminder else { return }
        item.isCompleted = true
        do {
            try store.save(item, commit: true)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                reminders.removeAll { $0.id == reminder.id }
            }
        } catch {
            NSSound.beep()
        }
    }

    func addReminder(titled title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let list = store.defaultCalendarForNewReminders() else { return }
        let item = EKReminder(eventStore: store)
        item.title = trimmed
        item.calendar = list
        do {
            try store.save(item, commit: true)
            loadReminders()
        } catch {
            NSSound.beep()
        }
    }

    // MARK: Private

    private func loadEvents() {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: .now)
        guard let end = calendar.date(byAdding: .day, value: 7, to: start) else { return }
        let showAllDay = AppSettings.shared.showAllDayEvents
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        events = store.events(matching: predicate)
            .filter { event in
                event.status != .canceled
                    && (showAllDay || !event.isAllDay)
                    && event.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined
            }
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                Event(id: "\(event.eventIdentifier ?? UUID().uuidString)-\(event.startDate.timeIntervalSince1970)",
                      title: event.title ?? "Untitled",
                      start: event.startDate,
                      end: event.endDate,
                      isAllDay: event.isAllDay,
                      color: Color(cgColor: event.calendar.cgColor),
                      meetingURL: Self.meetingURL(in: event))
            }
    }

    private func loadReminders() {
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        store.fetchReminders(matching: predicate) { [weak self] items in
            let reminders = (items ?? []).map { item in
                Reminder(id: item.calendarItemIdentifier,
                         title: item.title ?? "",
                         dueDate: item.dueDateComponents?.date ?? item.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                         color: Color(cgColor: item.calendar.cgColor))
            }
            .sorted { lhs, rhs in
                switch (lhs.dueDate, rhs.dueDate) {
                case let (left?, right?): left < right
                case (.some, nil): true
                default: false
                }
            }
            Task { @MainActor in self?.reminders = reminders }
        }
    }

    /// Announces an event in the closed notch five minutes before it starts, and again at the start.
    private func tick() {
        if !Calendar.current.isDate(loadedDay, inSameDayAs: .now) { reload() }
        guard AppSettings.shared.liveEvents, hasEventAccess else { return }
        let now = Date.now
        for event in events where !event.isAllDay {
            let minutes = event.start.timeIntervalSince(now) / 60
            if minutes > 0, minutes <= 5, announced.insert(event.id + "-soon").inserted {
                LiveActivityCenter.shared.post(LiveNotice(key: "event", symbol: "calendar", tint: event.color,
                                                          text: Format.countdown(to: event.start), detail: event.title), for: 6)
            } else if minutes <= 0, minutes > -1, announced.insert(event.id + "-now").inserted {
                LiveActivityCenter.shared.post(LiveNotice(key: "event", symbol: "calendar.badge.clock", tint: event.color,
                                                          text: "now", detail: event.title), for: 6)
            }
        }
    }

    private static let meetingHosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com",
                                       "webex.com", "whereby.com", "facetime.apple.com", "gotomeeting.com", "chime.aws"]

    /// The first video-call link in the event's URL, location or notes.
    private static func meetingURL(in event: EKEvent) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for text in [event.url?.absoluteString, event.location, event.notes].compactMap({ $0 }) {
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let url = match.url, let host = url.host?.lowercased() else { continue }
                if meetingHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return url }
            }
        }
        return nil
    }

    static func openPrivacySettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Snapshots

    func loadSample(events: [Event], reminders: [Reminder]) {
        eventAccess = .fullAccess
        reminderAccess = .fullAccess
        self.events = events
        self.reminders = reminders
    }
}
