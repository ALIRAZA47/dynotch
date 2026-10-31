import Foundation
import Testing
@testable import Dynotch

/// `NSDataDetector` reads from the real clock, so what's expected counts from it too. A test that
/// wants a time gone by passes a `now` later than the one the detector used.
struct EventTextTests {
    private func event(_ text: String, now: Date = .now) -> NewEvent? {
        if case .event(let event) = EventText.read(text, now: now) { return event }
        return nil
    }

    private func hour(_ date: Date?) -> Int? { date.map { Calendar.current.component(.hour, from: $0) } }

    private func length(_ text: String) -> TimeInterval? {
        event(text).map { $0.end.timeIntervalSince($0.start).rounded() }
    }

    /// A date as a person would type it, like "31 oct".
    private func day(_ offset: Int = 0) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM"
        return formatter.string(from: Calendar.current.date(byAdding: .day, value: offset, to: .now)!)
    }

    /// An hour after three this afternoon, whenever the tests run.
    private var pastThree: Date {
        Calendar.current.date(bySettingHour: 16, minute: 0, second: 0, of: .now)!
    }

    // MARK: Reading

    @Test func theExampleFromThePage() throws {
        let event = try #require(event("dentist fri 3pm"))
        #expect(event.title == "dentist")
        #expect(Calendar.current.component(.weekday, from: event.start) == 6)
        #expect(hour(event.start) == 15)
        #expect(event.start > .now)
        #expect(event.end.timeIntervalSince(event.start).rounded() == 3600)
    }

    @Test(arguments: [
        ("dentist fri 3 pm", "dentist", 15), ("Dentist Fri 3PM", "Dentist", 15), ("fri 3p dentist", "dentist", 15),
        ("flight BA117 fri 6:30am", "flight BA117", 6), ("standup tue 9.30am", "standup", 9), ("review tue 14:30", "review", 14),
        ("dentist fri at 3pm", "dentist", 15), ("dentist fri at 15", "dentist", 15),
        ("drinks fri noon", "drinks", 12), ("drinks tomorrow at noon", "drinks", 12), ("walk tomorrow morning", "walk", 9),
    ])
    func waysOfSayingWhen(text: String, title: String, hour expected: Int) {
        #expect(event(text)?.title == title)
        #expect(hour(event(text)?.start) == expected)
    }

    @Test func numbersInATitleStayInIt() {
        #expect(event("1:1 with sam fri 3pm")?.title == "1:1 with sam")
        #expect(event("sprint 12 review tue 2pm")?.title == "sprint 12 review")
        #expect(event("call 555-1234 at 3pm")?.title == "call 555-1234")
        #expect(event("review pr 17 mon 10:30")?.title == "review pr 17")
    }

    @Test func aTitleCanGoEitherSideOfTheTime() {
        #expect(event("fri 3pm dentist")?.title == "dentist")
        #expect(event("call fri 3pm with sam")?.title == "call with sam")
    }

    @Test func whatsLeftHangingComesOff() {
        #expect(event("dentist on friday at 3pm")?.title == "dentist")
        #expect(event("dentist, fri 3pm")?.title == "dentist")
    }

    /// These come back as a day at noon and a time today, and either alone would be a wrong event.
    @Test(arguments: [
        ("tomorrow call sam 5pm", "call sam", 17), ("fri dentist 3pm", "dentist", 15), ("monday standup 9am", "standup", 9),
        ("next friday team lunch 1pm", "team lunch", 13),
    ])
    func aDayApartFromItsTime(text: String, title: String, hour expected: Int) throws {
        let event = try #require(event(text))
        #expect(event.title == title)
        #expect(hour(event.start) == expected)
        #expect(event.start > .now)
        #expect(!Calendar.current.isDateInToday(event.start))
    }

    @Test func aDateBesideOrApartFromItsTime() throws {
        let next = day(3)
        for text in ["party \(next) 9pm", "\(next) party 9pm"] {
            let event = try #require(event(text))
            #expect(event.title == "party")
            #expect(hour(event.start) == 21)
            #expect(Calendar.current.isDate(event.start, inSameDayAs: Calendar.current.date(byAdding: .day, value: 3, to: .now)!))
        }
    }

    @Test func aRangeApartFromItsDay() {
        #expect(length("fri dentist 3-4pm") == 3600)
    }

    @Test func aMealInTheMiddle() {
        #expect(event("friday dinner with anna at 8pm")?.title == "dinner with anna")
        #expect(hour(event("friday dinner with anna at 8pm")?.start) == 20)
        #expect(event("dec 25 lunch at noon")?.title == "lunch")
    }

    /// The detector takes these for times of day, so they end up in what it matched.
    @Test func aMealIsAName() {
        #expect(event("lunch tomorrow at 1pm")?.title == "lunch")
        #expect(event("dinner tomorrow at 9")?.title == "dinner")
        #expect(event("breakfast fri 8am")?.title == "breakfast")
        #expect(event("sam lunch fri 1pm")?.title == "sam lunch")
        #expect(event("lunch with sam fri 1pm")?.title == "lunch with sam")
    }

    @Test func aZoneGivesTheLocalTime() throws {
        let start = try #require(event("call fri 3pm pst")?.start)
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        #expect(pacific.component(.hour, from: start) == 15)
    }

    // MARK: Length

    @Test(arguments: [
        ("standup mon 9am 30m", 1800), ("standup mon 9am 30 min", 1800), ("standup mon 9am for 15 min", 900),
        ("workshop fri 9am for 2 hours", 7200), ("workshop fri 9am 2h", 7200), ("offsite fri 9am 1h30", 5400),
        ("offsite fri 9am 1.5 hours", 5400), ("for 45 minutes review fri 2pm", 2700),
    ] as [(String, TimeInterval)])
    func aTypedLength(text: String, seconds: TimeInterval) {
        #expect(length(text) == seconds)
    }

    @Test func aLengthDoesntStayInTheTitle() {
        #expect(event("standup mon 9am 30m")?.title == "standup")
        #expect(event("workshop fri 9am for 2 hours")?.title == "workshop")
    }

    @Test func aRangeSetsTheLength() {
        #expect(length("lunch fri 12-1pm") == 3600)
        #expect(length("meeting fri 3pm to 5pm") == 7200)
        #expect(length("lunch from 12pm to 1pm") == 3600)
        #expect(length("offsite sat 9am to sun 5pm") == 115_200)
    }

    @Test func aTypedLengthBeatsARange() {
        #expect(length("meeting fri 3pm to 5pm for 30 min") == 1800)
    }

    @Test func aLengthAtTheFrontIsPartOfTheName() {
        #expect(event("2h workshop fri 3pm")?.title == "2h workshop")
        #expect(length("2h workshop fri 3pm") == 3600)
    }

    @Test func aBareNumberIsntALength() {
        #expect(length("dentist fri 3pm 45") == 3600)
        #expect(event("dentist fri 3pm 45")?.title == "dentist 45")
    }

    // MARK: What it won't guess

    /// Each of these comes back from the detector as a date, or as a title with no date in it. Taking
    /// either at its word would make an event at noon, or on the wrong day, or one called all of this.
    @Test(arguments: [
        "dentist", "dentist fri", "friday", "fri", "lunch fri", "lunch tomorrow", "sunday brunch", "dentist friday 3", "tomorrow 9",
        "dentist at 5", "dentist 5", "25 dec", "dentist 25 dec", "dentist next week", "standup 30m", "for 2 hours",
    ])
    func noTimeNoEvent(text: String) {
        #expect(EventText.read(text) == .noTime)
    }

    /// FX11: "in 2 hours" isn't read by `ReminderText` either, and `cal` is safe without it.
    @Test func aRelativeTimeIsntReadYet() {
        #expect(EventText.read("dentist in 2 hours") == .noTime)
        #expect(EventText.read("dentist in 30 minutes") == .noTime)
    }

    @Test(arguments: ["dentist tomorrow 3pm and gym fri 4pm", "meeting from fri 3pm to 5pm", "review 10:30 fri 3pm"])
    func twoTimesCantBeOneEvent(text: String) {
        #expect(EventText.read(text) == .severalTimes)
    }

    @Test(arguments: ["", "   "])
    func nothingAtAll(text: String) {
        #expect(EventText.read(text) == .noTime)
    }

    @Test(arguments: ["fri 3pm", "3pm", "tomorrow at noon", "lunch", "at 3pm on friday"])
    func aTimeNeedsAName(text: String) {
        if text == "lunch" {
            #expect(EventText.read(text) == .noTime)
        } else {
            #expect(EventText.read(text) == .noTitle)
        }
    }

    // MARK: A time that's gone

    @Test func aBareTimeThatsPassedMeansTomorrow() throws {
        let start = try #require(event("dentist 3pm", now: pastThree)?.start)
        #expect(Calendar.current.isDate(start, inSameDayAs: Calendar.current.date(byAdding: .day, value: 1, to: pastThree)!))
        #expect(hour(start) == 15)
        #expect(event("dentist 1-2pm", now: pastThree) != nil)
        #expect(event("dentist from 1pm to 2pm", now: pastThree) != nil)
    }

    @Test(arguments: ["dentist today 3pm", "dentist 3pm today", "today dentist 3pm"])
    func aTimeSaidToBeTodayStaysToday(text: String) {
        guard case .past = EventText.read(text, now: pastThree) else {
            Issue.record("It should have said the time had passed")
            return
        }
    }

    @Test func aDateThatsGoneStaysGone() {
        guard case .past = EventText.read("dentist \(day()) 3pm", now: pastThree) else {
            Issue.record("It should have said the time had passed")
            return
        }
    }

    @Test func aWeekdayNeverRollsToTheDayAfter() throws {
        let start = try #require(event("dentist fri 3pm")?.start)
        guard case .past = EventText.read("dentist fri 3pm", now: start.addingTimeInterval(3600)) else {
            Issue.record("It should have said the time had passed")
            return
        }
    }
}

/// The row, with a stand-in for the calendar that never reaches the real one.
@MainActor
@Suite(.serialized)
struct EventRowTests {
    @MainActor
    private final class Calendar: EventAdding {
        var hasEventAccess = true
        var accepts = true
        private(set) var added: [NewEvent] = []
        private(set) var asked = 0

        func requestEventAccess() { asked += 1 }

        func addEvent(_ event: NewEvent) -> Bool {
            if accepts { added.append(event) }
            return accepts
        }
    }

    private let calendar = Calendar()
    private let viewModel: NotchViewModel

    init() {
        SnapshotRenderer.useScratchDefaults()
        viewModel = NotchViewModel(geometry: NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                                           closedSize: CGSize(width: 186, height: 37), hasHardwareNotch: true))
    }

    private func row(_ body: String) -> CommandResult { CommandEngine.event(body, calendar: calendar) }

    @Test func theRowShowsWhenBeforeReturn() throws {
        let row = row("dentist fri 3pm")
        #expect(row.title == "Add event: dentist")
        let hint = try #require(row.hint)
        #expect(hint.hasSuffix(" · 1 hr"))
        #expect(hint.contains("3:00") || hint.contains("15:00"))
        #expect(calendar.added.isEmpty)
    }

    @Test func aTypedLengthShows() {
        #expect(row("standup mon 9am 30m").hint?.hasSuffix(" · 30 min") == true)
    }

    @Test func returnAddsTheEvent() throws {
        viewModel.run(row("dentist fri 3pm"))
        let event = try #require(calendar.added.first)
        #expect(calendar.added.count == 1)
        #expect(event.title == "dentist")
        #expect(event.end.timeIntervalSince(event.start).rounded() == 3600)
    }

    @Test(arguments: ["dentist", "dentist fri", "fri 3pm", "dentist in 2 hours", "dentist tomorrow 3pm and gym fri 4pm"])
    func returnAddsNothingWhenItCantRead(text: String) {
        let row = row(text)
        #expect(row.action == nil)
        viewModel.run(row)
        #expect(calendar.added.isEmpty)
    }

    @Test func itSaysWhatsMissing() {
        #expect(row("dentist fri").title == "No time in that yet")
        #expect(row("fri 3pm").title == "An event needs a name")
        #expect(row("dentist tomorrow 3pm and gym fri 4pm").title == "That reads as more than one time")
        #expect(row("").title == "Add an event")
        #expect(row("").action == nil)
    }

    @Test func aTimeThatsGoneAddsNothing() throws {
        let start = try #require(CalendarDateOfToday.three)
        let later = CommandEngine.event("dentist today 3pm", calendar: calendar, now: start.addingTimeInterval(3600))
        #expect(later.title == "That time has passed")
        #expect(later.action == nil)
    }

    @Test func withoutAccessItAsksAndAddsNothing() {
        calendar.hasEventAccess = false
        let row = row("dentist fri 3pm")
        #expect(row.title == "Allow Calendar first")
        viewModel.run(row)
        #expect(calendar.asked == 1)
        #expect(calendar.added.isEmpty)
    }

    @Test func aRefusalAddsNothing() {
        calendar.accepts = false
        viewModel.run(row("dentist fri 3pm"))
        #expect(calendar.added.isEmpty)
    }

    /// Only the row's ID: running it through the real field would ask the real calendar.
    @Test func theFieldOffersIt() {
        let first = CommandEngine.results(for: "cal dentist fri 3pm", in: viewModel).first
        #expect(first?.id == "cal")
        #expect(CommandEngine.results(for: "calendar dentist fri 3pm", in: viewModel).first?.id == "cal")
        #expect(CommandEngine.results(for: "cal", in: viewModel).first?.id == "cal")
    }

    @Test func anEventIsNotATimer() {
        #expect(!CommandEngine.results(for: "cal tea 4m", in: viewModel).map(\.id).contains("timer"))
    }

    @Test func itsCountedAsTheCommandAndNotWhatWasTyped() {
        #expect(CommandEngine.learnedID(of: "cal") == "cal")
        CommandHistory.forget()
        viewModel.run(row("dentist fri 3pm"))
        #expect(CommandHistory.ranked() == ["cal"])
    }
}

private enum CalendarDateOfToday {
    static var three: Date? { Calendar.current.date(bySettingHour: 15, minute: 0, second: 0, of: .now) }
}
