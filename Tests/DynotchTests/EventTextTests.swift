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
        ("drinks fri noon", "drinks", 12), ("drinks tomorrow at noon", "drinks", 12), ("drinks tonight at 8", "drinks", 20),
        ("standup tue 09:30", "standup", 9), ("night shift sat 22:00", "night shift", 22), ("dentist sun 3pm", "dentist", 15),
    ])
    func waysOfSayingWhen(text: String, title: String, hour expected: Int) {
        #expect(event(text)?.title == title)
        #expect(hour(event(text)?.start) == expected)
    }

    @Test func someShortWaysOfSayingWhenAreRead() throws {
        let tomorrow = try #require(event("dentist tmrw 3pm"))
        #expect(tomorrow.title == "dentist")
        #expect(Calendar.current.isDateInTomorrow(tomorrow.start))
        let later = try #require(event("dentist in 2 weeks 3pm"))
        #expect(later.title == "dentist")
        #expect(Calendar.current.isDate(later.start, inSameDayAs: Calendar.current.date(byAdding: .day, value: 14, to: .now)!))
    }

    @Test func numbersInATitleStayInIt() {
        #expect(event("1:1 with sam fri 3pm")?.title == "1:1 with sam")
        #expect(event("sprint 12 review tue 2pm")?.title == "sprint 12 review")
        #expect(event("call 555-1234 at 3pm")?.title == "call 555-1234")
        #expect(event("review pr 17 mon 10:30am")?.title == "review pr 17")
    }

    @Test func aTitleCanGoEitherSideOfTheTime() {
        #expect(event("fri 3pm dentist")?.title == "dentist")
        #expect(event("call fri 3pm with sam")?.title == "call with sam")
    }

    @Test func whatsLeftHangingComesOff() {
        #expect(event("dentist on friday at 3pm")?.title == "dentist")
        #expect(event("dentist, fri 3pm")?.title == "dentist")
    }

    @Test func whatLooksLikeADayButIsAName() {
        #expect(event("call sandy 3pm")?.title == "call sandy")
        #expect(event("call mandy fri 3pm")?.title == "call mandy")
        #expect(event("call tom 3pm")?.title == "call tom")
        #expect(event("call sam fri 3pm")?.title == "call sam")
        #expect(event("lunch with june fri 1pm")?.title == "lunch with june")
        #expect(event("march planning fri 3pm")?.title == "march planning")
        #expect(event("weekend trip sat 9am")?.title == "weekend trip")
    }

    @Test func titlesKeepTheirShape() {
        #expect(event("date night fri 8pm")?.title == "date night")
        #expect(event("movie night sat 9pm")?.title == "movie night")
        #expect(event("sync (design) fri 3pm")?.title == "sync (design)")
        #expect(event("review [urgent] fri 3pm")?.title == "review [urgent]")
        #expect(event("meetup c# fri 3pm")?.title == "meetup c#")
        #expect(event("@sam sync fri 3pm")?.title == "@sam sync")
        #expect(event("drop by fri 3pm")?.title == "drop by")
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
        #expect(event("dinner tomorrow at 9pm")?.title == "dinner")
        #expect(event("breakfast fri 8am")?.title == "breakfast")
        #expect(event("sam lunch fri 1pm")?.title == "sam lunch")
        #expect(event("lunch with sam fri 1pm")?.title == "lunch with sam")
    }

    private func hour(_ date: Date?, in zone: String) -> Int? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return date.map { calendar.component(.hour, from: $0) }
    }

    /// The detector only reads some zones, and leaves the rest in the title with a local time. In
    /// capitals or not, it mustn't matter.
    @Test(arguments: [
        ("call fri 3pm pst", "America/Los_Angeles"), ("call fri 3pm est", "America/New_York"), ("call fri 3pm EST", "America/New_York"),
        ("call fri 3pm Est", "America/New_York"), ("call fri 3pm et", "America/New_York"), ("call fri 3pm pt", "America/Los_Angeles"),
        ("call fri 3pm ist", "Asia/Kolkata"), ("call fri 3pm pkt", "Asia/Karachi"), ("call fri 3pm sgt", "Asia/Singapore"),
        ("call fri 3pm aest", "Australia/Sydney"), ("call fri 3pm cet", "Europe/Paris"), ("call fri 3pm lahore time", "Asia/Karachi"),
        ("call fri 3pm new york time", "America/New_York"), ("call fri 3pm nyc time", "America/New_York"),
        ("call fri 3pm sf time", "America/Los_Angeles"), ("call fri 3pm tokyo time", "Asia/Tokyo"),
    ])
    func aZoneGivesTheLocalTime(text: String, zone: String) {
        #expect(event(text)?.title == "call")
        #expect(hour(event(text)?.start, in: zone) == 15)
    }

    @Test func aWordThatsAlsoAZoneStaysAWord() {
        #expect(event("dentist 3pm art class")?.title == "dentist art class")
        #expect(hour(event("dentist 3pm art class")?.start) == 15)
        #expect(event("fri 3pm pt session")?.title == "pt session")
    }

    @Test(arguments: ["call est 3pm", "call pkt fri 3pm", "call lahore time 3pm", "call new york time fri 3pm"])
    func aZoneAwayFromTheTimeIsntGuessedAt(text: String) {
        #expect(EventText.read(text) == .unclearZone)
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

    @Test(arguments: [
        ("meeting fri 3pm for an hour", 3600), ("meeting fri 3pm for half an hour", 1800), ("meeting fri 3pm for 1 hour and 30 minutes", 5400),
        ("meeting fri 3pm 1 hour and 30 minutes", 5400), ("standup for 30 min 9:30am mon", 1800), ("standup for 1h 9:30am mon", 3600),
    ] as [(String, TimeInterval)])
    func lengthsInWords(text: String, seconds: TimeInterval) {
        #expect(length(text) == seconds)
        #expect(event(text)?.title == (text.hasPrefix("standup") ? "standup" : "meeting"))
    }

    @Test(arguments: ["meeting fri 3pm for 3 days", "meeting fri 3pm for 25 hours", "meeting for 2 weeks fri 3pm"])
    func aLengthItCantUseIsSaid(text: String) {
        #expect(EventText.read(text) == .unclearLength)
    }

    @Test func aForThatIsntALengthStays() {
        #expect(event("team lunch for 2 fri 1pm")?.title == "team lunch for 2")
        #expect(event("flowers for mom fri 3pm")?.title == "flowers for mom")
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
        "walk tomorrow morning", "dinner tonight", "drinks tonight 8", "call tomorrow morning 10", "call fri morning 10", "drinks this evening",
        "party 25.12.2026", "party 25.12.26", "party on 25.12.2026", "party 31.12.2026", "party 12.25.2026", "party 2026.11.05",
        "party 2026/11/05", "dentist at 2026-11-05", "dentist 13pm", "dentist fri 0pm", "dentist fri 25:00",
    ])
    func noTimeNoEvent(text: String) {
        #expect(EventText.read(text) == .noTime)
    }

    /// Whether these are morning or afternoon depends on the hour they're typed, going by the detector.
    @Test(arguments: ["dentist 3:30", "dentist 1:00", "dentist 9:30", "dentist 10:30", "dentist 12:30", "dentist fri at 7", "call mon at 8",
                      "call fri at 3", "dentist fri 4.15"])
    func aTimeThatCouldBeEitherAsksWhich(text: String) {
        #expect(EventText.read(text) == .needsAMOrPM)
    }

    /// Each of these left the day in the title, with an event today. It's the case this all exists for.
    @Test(arguments: [
        "dentist tomorow 3pm", "dentist tommorow 3pm", "dentist tommorrow 3pm", "dentist tmr 3pm", "dentist tmw 3pm",
        "dentist fir 3pm", "dentist firday 3pm", "dentist mondy 3pm", "dentist tuseday 3pm", "dentist saterday 3pm", "dentist wednsday 3pm",
        "dentist next week 3pm", "dentist in a week 3pm", "dentist 2 days from now 3pm", "dentist next month 3pm", "trip this weekend 3pm",
        "dentist in december 3pm", "standup mondays 9am", "party christmas 3pm", "party thanksgiving 3pm", "dentist a week from friday 3pm",
        "every friday 3pm dentist", "sun dentist 3pm",
    ])
    func aDayLeftInTheTitleIsntAnEvent(text: String) {
        #expect(EventText.read(text) == .unclearDay)
    }

    @Test(arguments: ["dentist nov 31 3pm", "dentist 31 nov 3pm", "dentist feb 30 3pm", "dentist 31 april 3pm"])
    func aDayTheMonthDoesntHave(text: String) {
        #expect(EventText.read(text) == .noSuchDate)
    }

    @Test(arguments: ["focus until 3pm", "work fri until 5pm", "work until 5pm fri", "call till 4pm"])
    func anEndAloneIsntAStart(text: String) {
        #expect(EventText.read(text) == .noStart)
    }

    /// FX11: "in 2 hours" isn't read by `ReminderText` either, and `cal` is safe without it.
    @Test func aRelativeTimeIsntReadYet() {
        #expect(EventText.read("dentist in 2 hours") == .noTime)
        #expect(EventText.read("dentist in 30 minutes") == .noTime)
    }

    @Test(arguments: ["dentist tomorrow 3pm and gym fri 4pm", "meeting from fri 3pm to 5pm", "review 10:30 fri 3pm",
                      "24/7 support sync 3pm", "sprint 11/12 review 3pm", "7/11 run 3pm", "meeting 3pm-2pm", "fri 3pm to fri 5pm dentist"])
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

    /// The detector always gives the next one after today. So to have it land on what's "today" here,
    /// `now` goes a week before the date it gave.
    @Test func todaysWeekdayMeansTodayWhileTheTimeIsAhead() throws {
        let start = try #require(event("dentist fri 3pm")?.start)
        let week = try #require(Calendar.current.date(byAdding: .day, value: -7, to: start))
        #expect(event("dentist fri 3pm", now: week.addingTimeInterval(-3600))?.start == week)
        #expect(event("fri dentist 3pm", now: week.addingTimeInterval(-3600))?.start == week)
    }

    @Test func nextMeansNext() throws {
        let start = try #require(event("dentist next fri 3pm")?.start)
        let week = try #require(Calendar.current.date(byAdding: .day, value: -7, to: start))
        #expect(event("dentist next fri 3pm", now: week.addingTimeInterval(-3600))?.start == start)
    }
}

/// The row, with a stand-in for the calendar that never reaches the real one.
@MainActor
@Suite(.serialized)
struct EventRowTests {
    @MainActor
    private final class FakeCalendar: EventAdding {
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

    private let calendar = FakeCalendar()
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

    @Test(arguments: ["dentist", "dentist fri", "fri 3pm", "dentist in 2 hours", "dentist tomorrow 3pm and gym fri 4pm", "dentist 3:30",
                      "dentist tomorow 3pm", "dentist nov 31 3pm", "focus until 3pm", "call est 3pm", "meeting fri 3pm for 3 days"])
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
        #expect(row("dentist 3:30").title == "Add am or pm to the time")
        #expect(row("dentist tomorow 3pm").title == "Can't read the day in that")
        #expect(row("dentist nov 31 3pm").title == "There's no such date")
        #expect(row("focus until 3pm").title == "Say when it starts")
        #expect(row("call est 3pm").title == "Put the time zone right after the time")
        #expect(row("meeting fri 3pm for 3 days").title == "Can't read how long that is")
    }

    @Test func aYearOtherThanThisOneShows() throws {
        let later = try #require(Foundation.Calendar.current.date(byAdding: .year, value: 2, to: .now))
        #expect(ReminderText.describe(later).contains(String(Foundation.Calendar.current.component(.year, from: later))))
        let soon = try #require(Foundation.Calendar.current.date(byAdding: .day, value: 2, to: .now))
        if Foundation.Calendar.current.isDate(soon, equalTo: .now, toGranularity: .year) {
            #expect(!ReminderText.describe(soon).contains(String(Foundation.Calendar.current.component(.year, from: soon))))
        }
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

    /// Only the rows' IDs: running one through the real field would ask the real calendar, whose
    /// answer on this Mac isn't known. The sample gives the field access without reaching EventKit.
    @Test func theFieldOffersIt() {
        CalendarService.shared.loadSample(events: [], reminders: [])
        #expect(CommandEngine.results(for: "cal dentist fri 3pm", in: viewModel).first?.id == "cal")
        #expect(CommandEngine.results(for: "calendar dentist fri 3pm", in: viewModel).first?.id == "cal")
        #expect(CommandEngine.results(for: "cal", in: viewModel).first?.id == "cal")
    }

    @Test func aReadableEventSpeaksForTheLine() {
        CalendarService.shared.loadSample(events: [], reminders: [])
        #expect(!CommandEngine.results(for: "cal standup mon 9am 30m", in: viewModel).map(\.id).contains("timer"))
    }

    /// What the line did before `cal` meant anything still works, as this row can't do anything.
    @Test func anUnreadEventComesLast() {
        CalendarService.shared.loadSample(events: [], reminders: [])
        let results = CommandEngine.results(for: "cal tea 4m", in: viewModel)
        #expect(results.first?.id == "timer")
        #expect(results.last?.id == "cal")
        #expect(results.last?.action == nil)
    }

    @Test func aPermissionRowIsntAUse() {
        CommandHistory.forget()
        calendar.hasEventAccess = false
        viewModel.run(row("dentist fri 3pm"))
        #expect(CommandHistory.ranked().isEmpty)
    }

    @Test func itsCountedAsTheCommandAndNotWhatWasTyped() {
        #expect(CommandEngine.learnedID(of: "cal") == "cal")
        CommandHistory.forget()
        viewModel.run(row("dentist fri 3pm"))
        #expect(CommandHistory.ranked() == ["cal"])
    }
}

private enum CalendarDateOfToday {
    static var three: Date? { Foundation.Calendar.current.date(bySettingHour: 15, minute: 0, second: 0, of: .now) }
}
