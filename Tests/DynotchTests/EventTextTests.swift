import Foundation
import Testing
@testable import Dynotch

private func calendar(in zone: String = "Asia/Karachi") -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar
}

/// "2026-11-06 15:00" on the clock in that zone.
private func moment(_ text: String, in zone: String = "Asia/Karachi") -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: zone)
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.date(from: text)!
}

/// All of it reads from one moment: Wednesday 4 November 2026, 10:00 in Lahore.
struct EventTextTests {
    private let now = moment("2026-11-04 10:00")

    private func read(_ text: String, at now: Date? = nil) -> EventText.Reading {
        EventText.read(text, now: now ?? self.now, calendar: calendar())
    }

    private func event(_ text: String, at now: Date? = nil) -> NewEvent? {
        if case .event(let event) = read(text, at: now) { return event }
        return nil
    }

    private func length(_ text: String) -> TimeInterval? { event(text).map { $0.end.timeIntervalSince($0.start) } }

    private func isPast(_ reading: EventText.Reading) -> Bool {
        if case .past = reading { return true }
        return false
    }

    // MARK: Reading

    @Test func theExampleFromThePage() {
        #expect(read("dentist fri 3pm") == .event(NewEvent(title: "dentist", start: moment("2026-11-06 15:00"), end: moment("2026-11-06 16:00"))))
    }

    @Test(arguments: [
        ("dentist fri 3 pm", "dentist", "2026-11-06 15:00"), ("Dentist Fri 3PM", "Dentist", "2026-11-06 15:00"),
        ("dentist fri 3 p.m.", "dentist", "2026-11-06 15:00"), ("flight BA117 fri 6:30am", "flight BA117", "2026-11-06 06:30"),
        ("standup tue 9.30am", "standup", "2026-11-10 09:30"), ("review tue 14:30", "review", "2026-11-10 14:30"),
        ("review tue 14.30", "review", "2026-11-10 14:30"), ("standup tue 09:30", "standup", "2026-11-10 09:30"),
        ("night shift sat 22:00", "night shift", "2026-11-07 22:00"), ("night shift sat 00:30", "night shift", "2026-11-07 00:30"),
        ("dentist fri at 3pm", "dentist", "2026-11-06 15:00"), ("dentist fri at 15", "dentist", "2026-11-06 15:00"),
        ("dentist fri @ 3pm", "dentist", "2026-11-06 15:00"), ("dentist fri, 3pm", "dentist", "2026-11-06 15:00"),
        ("dentist sun. 3pm", "dentist", "2026-11-08 15:00"), ("dentist sun @ 3pm", "dentist", "2026-11-08 15:00"),
        ("dentist on friday at 3pm", "dentist", "2026-11-06 15:00"), ("dentist, fri 3pm", "dentist", "2026-11-06 15:00"),
        ("dentist 3pm fri", "dentist", "2026-11-06 15:00"), ("dentist 3pm on fri", "dentist", "2026-11-06 15:00"),
        ("drinks fri noon", "drinks", "2026-11-06 12:00"), ("drinks tomorrow at noon", "drinks", "2026-11-05 12:00"),
        ("call fri midnight", "call", "2026-11-07 00:00"),
    ])
    func waysOfSayingWhen(text: String, title: String, start: String) {
        #expect(event(text)?.title == title)
        #expect(event(text)?.start == moment(start))
    }

    @Test(arguments: [
        ("dentist today 3pm", "2026-11-04 15:00"), ("dentist 3pm today", "2026-11-04 15:00"), ("dentist tomorrow 3pm", "2026-11-05 15:00"),
        ("dentist tmrw 3pm", "2026-11-05 15:00"), ("dentist tmr 3pm", "2026-11-05 15:00"), ("dentist tmw 3pm", "2026-11-05 15:00"),
        ("drinks tonight 8pm", "2026-11-04 20:00"), ("drinks tonight at 8", "2026-11-04 20:00"), ("drinks tonight 8:30", "2026-11-04 20:30"),
        ("dentist next fri 3pm", "2026-11-13 15:00"), ("dentist this fri 3pm", "2026-11-06 15:00"), ("dentist next wed 3pm", "2026-11-11 15:00"),
        ("party 25 dec 9pm", "2026-12-25 21:00"), ("party dec 25 9pm", "2026-12-25 21:00"), ("party 25th of december 9pm", "2026-12-25 21:00"),
        ("party dec 25th 9pm", "2026-12-25 21:00"), ("party dec. 25 9pm", "2026-12-25 21:00"), ("party the 25th of dec 9pm", "2026-12-25 21:00"),
        ("party 25 dec 2027 9pm", "2027-12-25 21:00"), ("party dec 25, 2027 9pm", "2027-12-25 21:00"), ("party 2026-12-25 9pm", "2026-12-25 21:00"),
        ("party 2026/12/25 9pm", "2026-12-25 21:00"), ("party 2027-1-5 9pm", "2027-01-05 21:00"),
        ("party 1 jan 9pm", "2027-01-01 21:00"), ("party 4 nov 9pm", "2026-11-04 21:00"),
    ])
    func whichDay(text: String, start: String) {
        #expect(event(text)?.start == moment(start))
    }

    /// A weekday beside a date is there to check it. These were moved to the coming Sunday or Friday.
    @Test(arguments: [
        ("dentist sun nov 8 3pm", "2026-11-08 15:00"), ("dentist sunday 8 nov 3pm", "2026-11-08 15:00"), ("dentist fri nov 13 3pm", "2026-11-13 15:00"),
        ("dentist friday 13th 3pm", "2026-11-13 15:00"), ("dentist friday the 13th 3pm", "2026-11-13 15:00"), ("fri 13th dentist 3pm", "2026-11-13 15:00"),
        ("dentist fri, dec 25 3pm", "2026-12-25 15:00"), ("dentist fri 2026-11-06 3pm", "2026-11-06 15:00"),
    ])
    func aWeekdayBesideADate(text: String, start: String) {
        #expect(event(text)?.title == "dentist")
        #expect(event(text)?.start == moment(start))
    }

    @Test(arguments: ["dentist sat nov 13 3pm", "dentist fri nov 12 3pm", "dentist sat 13th 3pm", "dentist thu 2026-11-06 3pm"])
    func aWeekdayTheDateDoesntFallOn(text: String) {
        #expect(read(text) == .noSuchDate)
    }

    @Test(arguments: [
        ("tomorrow call sam 5pm", "call sam", "2026-11-05 17:00"), ("fri dentist 3pm", "dentist", "2026-11-06 15:00"),
        ("monday standup 9am", "standup", "2026-11-09 09:00"), ("mon dentist 3pm", "dentist", "2026-11-09 15:00"),
        ("next friday team lunch 1pm", "team lunch", "2026-11-13 13:00"), ("friday dinner with anna at 8pm", "dinner with anna", "2026-11-06 20:00"),
        ("dec 25 lunch at noon", "lunch", "2026-12-25 12:00"), ("25 dec party 9pm", "party", "2026-12-25 21:00"),
        ("today dentist 3pm", "dentist", "2026-11-04 15:00"), ("tomorrow's standup 9am", "standup", "2026-11-05 09:00"),
        ("tonight's dinner 8pm", "dinner", "2026-11-04 20:00"), ("sunday brunch 11am", "brunch", "2026-11-08 11:00"),
        ("on fri dentist 3pm", "dentist", "2026-11-06 15:00"), ("drinks friday night 8pm", "drinks", "2026-11-06 20:00"),
        ("fri night date 8pm", "date", "2026-11-06 20:00"),
    ])
    func aDayCanOpenTheLine(text: String, title: String, start: String) {
        #expect(event(text)?.title == title)
        #expect(event(text)?.start == moment(start))
    }

    @Test func aTitleCanGoEitherSideOfTheWhen() {
        #expect(event("fri 3pm dentist")?.title == "dentist")
        #expect(event("call fri 3pm with sam")?.title == "call with sam")
    }

    @Test func numbersInATitleStayInIt() {
        #expect(event("1:1 with sam fri 3pm")?.title == "1:1 with sam")
        #expect(event("sprint 12 review tue 2pm")?.title == "sprint 12 review")
        #expect(event("call 555-1234 fri at 3pm")?.title == "call 555-1234")
        #expect(event("review pr 17 mon 10:30am")?.title == "review pr 17")
        #expect(event("version 2.15 review fri 3pm")?.title == "version 2.15 review")
        #expect(event("24/7 support sync fri 3pm")?.title == "24/7 support sync")
        #expect(event("sprint 11/12 review fri 3pm")?.title == "sprint 11/12 review")
        #expect(event("visit apt 5a fri 3pm")?.title == "visit apt 5a")
        #expect(event("room 3p fri 3pm")?.title == "room 3p")
    }

    @Test(arguments: [
        "call sandy fri 3pm", "call mandy fri 3pm", "call tom fri 3pm", "lunch with june fri 1pm", "march planning fri 3pm", "weekend trip sat 9am",
        "may the fourth party fri 8pm", "date night fri 8pm", "movie night sat 9pm", "sync (design) fri 3pm", "review [urgent] fri 3pm",
        "meetup c# fri 3pm", "@sam sync fri 3pm", "drop by fri 3pm", "on call fri 9am", "at home fri 9am", "on site visit fri 9am",
        "pay gst fri 3pm", "review bst fri 3pm", "year 9 ict fri 3pm", "breakfast fri 8am", "sam lunch fri 1pm", "lunch with sam fri 1pm",
        "catch up next fri 3pm",
    ])
    func aTitleStaysAsTyped(text: String) throws {
        let title = try #require(event(text)?.title)
        #expect(text.hasPrefix(title))
    }

    // MARK: Zones

    /// The time is the one there, and the day is the one on this calendar.
    @Test(arguments: [
        ("call fri 3pm pst", "America/Los_Angeles"), ("call fri 3pm est", "America/New_York"), ("call fri 3pm EST", "America/New_York"),
        ("call fri 3pm Est", "America/New_York"), ("call fri 3pm ET", "America/New_York"), ("call fri 3pm PT", "America/Los_Angeles"),
        ("call fri 3pm ist", "Asia/Kolkata"), ("call fri 3pm pkt", "Asia/Karachi"), ("call fri 3pm sgt", "Asia/Singapore"),
        ("call fri 3pm aest", "Australia/Sydney"), ("call fri 3pm cet", "Europe/Paris"), ("call fri 3pm lahore time", "Asia/Karachi"),
        ("call fri 3pm new york time", "America/New_York"), ("call fri 3pm nyc time", "America/New_York"), ("call fri 3pm sf time", "America/Los_Angeles"),
        ("call fri 3pm tokyo time", "Asia/Tokyo"), ("call 3pm est fri", "America/New_York"), ("call 3pm est on fri", "America/New_York"),
        ("call fri 3pm (est)", "America/New_York"), ("call fri 3pm [est]", "America/New_York"), ("call fri 3pm e.s.t.", "America/New_York"),
        ("call fri 3pm sast", "Africa/Johannesburg"), ("call fri 3pm npt", "Asia/Kathmandu"), ("call fri 3pm wita", "Asia/Makassar"),
        ("call fri 3pm azt", "Asia/Baku"), ("call fri 3pm nzt", "Pacific/Auckland"), ("call fri 3pm AFT", "Asia/Kabul"), ("call fri 3pm EAT", "Africa/Addis_Ababa"),
    ])
    func aZoneGivesTheTimeThere(text: String, zone: String) {
        #expect(event(text)?.title == "call")
        #expect(event(text)?.start == moment("2026-11-06 15:00", in: zone))
    }

    @Test func localTimeIsNoZoneAtAll() {
        #expect(event("call fri 3pm local time")?.title == "call")
        #expect(event("call fri 3pm local time")?.start == moment("2026-11-06 15:00"))
    }

    /// 3pm in New York on a Friday is the small hours of Saturday here, and that's still this Friday.
    @Test(arguments: ["call fri 3pm est", "call fri 3pm new york time", "fri call 3pm est"])
    func aZoneDoesntPushTheDayToNextWeek(text: String) {
        let friday = moment("2026-11-06 10:00")
        #expect(event(text, at: friday)?.start == moment("2026-11-06 15:00", in: "America/New_York"))
        #expect(event(text, at: friday)?.start == moment("2026-11-07 01:00"))
    }

    @Test(arguments: [
        ("meet fri 3pm sgt jones", "meet sgt jones", "15:00"), ("pay fri 3pm gst return", "pay gst return", "15:00"),
        ("train fri 9am central station", "train central station", "09:00"), ("hospital fri 3pm CT scan", "hospital CT scan", "15:00"),
        ("dentist fri 3pm art class", "dentist art class", "15:00"), ("vet fri 3pm cat", "vet cat", "15:00"),
        ("meet fri 3pm central park", "meet central park", "15:00"), ("drinks fri 6pm pacific beach", "drinks pacific beach", "18:00"),
        ("lunch fri 1pm eastern market", "lunch eastern market", "13:00"), ("meet fri 3pm london bridge", "meet london bridge", "15:00"),
        ("visit fri 3pm mountain view", "visit mountain view", "15:00"), ("trip fri 9am atlantic city", "trip atlantic city", "09:00"),
    ])
    func wordsAfterTheTimeAreTheTitle(text: String, title: String, time: String) {
        #expect(event(text)?.title == title)
        #expect(event(text)?.start == moment("2026-11-06 " + time))
    }

    @Test func aWordAfterTheTimeInLowercaseStaysAWord() {
        #expect(event("fri 3pm art")?.title == "art")
        #expect(event("fri 3pm pet")?.start == moment("2026-11-06 15:00"))
        #expect(event("fri 3pm PT session")?.title == "PT session")
    }

    @Test(arguments: [
        "gym fri 6pm pt", "call fri 3pm et", "call fri 3pm et/pt", "call fri 3pm gmt+5", "call fri 3pm hawaii time", "call fri 3pm central european time",
        "call fri 3pm aus time", "fri 3pm est dentist", "call est 3pm", "call pkt fri 3pm", "call lahore time 3pm", "call new york time fri 3pm",
    ])
    func aZoneThatCantBeReadIsSaid(text: String) {
        #expect(read(text) == .unclearZone)
    }

    // MARK: Length

    @Test(arguments: [
        ("standup mon 9am 30m", 1800), ("standup mon 9am 30 min", 1800), ("standup mon 9am for 15 min", 900),
        ("workshop fri 9am for 2 hours", 7200), ("workshop fri 9am 2h", 7200), ("offsite fri 9am 1h30", 5400),
        ("offsite fri 9am 1.5 hours", 5400), ("offsite fri 9am 1,5 hours", 5400), ("for 45 minutes review fri 2pm", 2700),
    ] as [(String, TimeInterval)])
    func aTypedLength(text: String, seconds: TimeInterval) {
        #expect(length(text) == seconds)
    }

    @Test func aLengthDoesntStayInTheTitle() {
        #expect(event("standup mon 9am 30m")?.title == "standup")
        #expect(event("workshop fri 9am for 2 hours")?.title == "workshop")
    }

    @Test(arguments: [
        ("lunch fri 12-1pm", 3600), ("meeting fri 3pm to 5pm", 7200), ("lunch fri from 12pm to 1pm", 3600), ("meeting from fri 3pm to 5pm", 7200),
        ("meeting fri 3pm until 5pm", 7200), ("work fri 9am till 5pm", 28800), ("workshop fri 9am til 5pm", 28800), ("meeting fri 14:00-15:00", 3600),
        ("standup fri 09:00-09:30", 1800), ("meeting fri 09:00-17:00", 28800), ("party sat 9pm-2am", 18000), ("fri 3-4pm dentist", 3600),
        ("fri dentist 3-4pm", 3600), ("work fri 9-5pm", 28800), ("party fri 9pm-midnight", 10800), ("lunch fri noon-2pm", 7200), ("lunch fri 11-1pm", 7200),
        ("lunch fri 11:30-1pm", 5400), ("lunch fri 12-2pm", 7200),
    ] as [(String, TimeInterval)])
    func aRangeSetsTheLength(text: String, seconds: TimeInterval) {
        #expect(length(text) == seconds)
    }

    @Test func aRangeStartsWhenItSays() {
        #expect(event("lunch fri 11-1pm")?.start == moment("2026-11-06 11:00"))
        #expect(event("lunch fri 12-1pm")?.start == moment("2026-11-06 12:00"))
        #expect(event("work fri 9-5pm")?.start == moment("2026-11-06 09:00"))
        #expect(event("party sat 9pm-2am")?.start == moment("2026-11-07 21:00"))
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

    @Test(arguments: ["meeting fri 3pm for 3 days", "meeting fri 3pm for 25 hours", "meeting for 2 weeks fri 3pm", "trip fri 9am 3 days"])
    func aLengthItCantUseIsSaid(text: String) {
        #expect(read(text) == .unclearLength)
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

    @Test(arguments: [
        "dentist", "dentist fri", "friday", "fri", "lunch fri", "lunch tomorrow", "sunday brunch", "dentist friday 3", "tomorrow 9", "dentist 5",
        "25 dec", "dentist 25 dec", "dentist next week", "standup 30m", "for 2 hours", "walk tomorrow morning", "dinner tonight", "drinks tonight 8",
        "call tomorrow morning 10", "call fri morning 10", "drinks this evening", "party 25.12.2026", "party 25.12.26", "party on 25.12.2026",
        "party 31.12.2026", "party 12.25.2026", "party 2026.11.05", "party 2026/11/05", "dentist at 2026-11-05", "dentist 13pm", "dentist fri 0pm",
        "dentist fri 25:00", "dentist fri 3:75pm", "party tonight at 0", "dentist fri 4.15", "dentist fri 3-4", "visit apt 5a fri", "room 3p fri", "unit 7a mon",
    ])
    func noTimeNoEvent(text: String) {
        #expect(read(text) == .noTime)
    }

    /// Without a day it reads, there's no telling a title from a day it got wrong, so a time alone
    /// isn't an event. Each of these was an event today at some point.
    @Test(arguments: [
        "dentist 3pm", "call sam 5pm", "dentist tomorow 3pm", "dentist tommorow 3pm", "dentist tommorrow 3pm", "dentist tmrow 3pm", "dentist 2mrw 3pm",
        "dentist overmorrow 3pm", "dentist fir 3pm", "dentist firday 3pm", "dentist mondy 3pm", "dentist tuseday 3pm", "dentist saterday 3pm",
        "dentist wednsday 3pm", "dentist wensday 3pm", "dentist thrs 3pm", "dentist tus 3pm", "dentist sund 3pm", "dentist fr 3pm", "dentist mo 3pm",
        "dentist next week 3pm", "dentist in a week 3pm", "dentist 2 days from now 3pm", "dentist next month 3pm", "trip this weekend 3pm",
        "dentist in december 3pm", "dentist in may 3pm", "next may party 3pm", "next summer party 3pm", "standup mondays 9am", "party christmas 3pm",
        "party thanksgiving 3pm", "new years party 9pm", "new years day brunch 11am", "nye party 9pm", "valentines day dinner 8pm", "boxing day lunch 1pm",
        "mother's day lunch 1pm", "labor day bbq 1pm", "dentist 5th 3pm", "dentist the fifth 3pm", "dentist febuary 3 3pm",
        "dentist novmber 3 3pm", "dentist in three days 3pm", "dentist in four weeks 3pm", "dentist in 2 wks 3pm", "dentist in a few days 3pm",
        "dentist 3 days later 3pm", "dentist end of month 3pm", "dentist 11/13 3pm", "dentist 11/31 3pm", "dentist 2/30 3pm", "dentist 31/11 3pm",
        "dentist 11-13 3pm", "24/7 support sync 3pm", "sprint 11/12 review 3pm", "leave mon-fri 9am", "trip fri-sun 8am", "conference nov 5-7 9am", "call dom 3pm",
        "lunch with dom 1pm", "call sab 3pm", "up next 3pm", "dentist @ 3pm", "lunch with frida 1pm", "sundae party 3pm", "call june 3pm",
    ])
    func aTimeAloneIsntAnEvent(text: String) {
        #expect(read(text) == .noDay)
    }

    /// These come out the same whatever day and hour they're typed.
    @Test(arguments: ["dentist 3:30", "dentist 1:00", "dentist 9:30", "dentist 10:30", "dentist 12:30", "dentist fri at 7", "call mon at 8", "call fri at 3",
                      "dentist at 5", "party tonight at 1", "party tonight at 2", "party tonight at 12", "party sat 9-2am", "party sat 8-1am", "party sat 10-2am",
                      "night shift fri 10-6am", "gym fri 12-1am", "dentist fri 3pm-5", "lunch fri 9-noon"])
    func aTimeThatCouldBeEitherAsksWhich(text: String) {
        #expect(read(text) == .needsAMOrPM)
    }

    @Test(arguments: [
        "dentist fri with sam 3pm", "dentist first monday of december 3pm", "dentist 2nd fri 3pm", "dentist the friday after next 3pm", "dentist fri week 3pm",
        "dentist tuesday week 3pm", "fri week dentist 3pm", "friday after next dentist 3pm", "black friday sale 9am", "good friday service 10am",
        "easter sunday lunch 1pm", "dentist after tomorrow 3pm", "dentist day after tomorrow 3pm", "every friday 3pm dentist", "call fri 3pm every week",
        "dentist fri 3pm next week", "dentist next week fri 3pm", "dentist fri 3pm in 2 weeks", "lunch with sun 1pm", "call mr sun 3pm", "dentist fri 11/13 3pm",
        "dentist fri 13 3pm", "meet fri bis 3pm", "dentist the friday 3pm", "dentist a week from friday 3pm",
    ])
    func aDayItCantTakeAtItsWordIsSaid(text: String) {
        #expect(read(text) == .unclearDay)
    }

    @Test(arguments: ["dentist nov 31 3pm", "dentist 31 nov 3pm", "dentist feb 30 3pm", "dentist 31 april 3pm", "dentist 31 nov 2026 3pm",
                      "dentist 2027-02-30 3pm", "dentist 2026-13-01 3pm", "dentist feb 29 3pm", "call nov 31 3pm pst", "call feb 30 3pm pst"])
    func aDayTheMonthDoesntHave(text: String) {
        #expect(read(text) == .noSuchDate)
    }

    /// The clocks go from 2:00 to 3:00 that morning.
    @Test func aTimeTheClocksSkip() {
        let newYork = calendar(in: "America/New_York")
        #expect(EventText.read("dentist 2027-03-14 2:30am", now: now, calendar: newYork) == .noSuchDate)
        if case .event = EventText.read("dentist 2027-03-14 3:30am", now: now, calendar: newYork) {} else {
            Issue.record("The hour after the change is there")
        }
    }

    @Test(arguments: ["focus fri until 3pm", "work fri until 5pm", "work until 5pm fri", "call till 4pm", "meeting ends fri 3pm", "meeting ends 3pm",
                      "meeting fri ends at 3pm", "call end 3pm", "project end fri 5pm", "workshop finishes 5pm", "shift ending 6pm", "drinks after 8pm fri"])
    func anEndAloneIsntAStart(text: String) {
        #expect(read(text) == .noStart)
    }

    /// FX11: "in 2 hours" isn't read by `ReminderText` either, and `cal` is safe without it.
    @Test func aRelativeTimeIsntReadYet() {
        #expect(read("dentist in 2 hours") == .noTime)
        #expect(read("dentist in 30 minutes") == .noTime)
    }

    @Test(arguments: ["dentist tomorrow 3pm and gym fri 4pm", "review 10:30 fri 3pm", "meeting fri 3pm-2pm", "fri 3pm to fri 5pm dentist", "offsite sat 9am to sun 5pm",
                      "leave mon to fri 9am", "standup mon to fri 9am", "conference mon to wed 9am", "sat exam fri 9am", "dentist fri or sat 3pm", "dentist fri 3pm tomorrow", "party 25.12. 9pm"])
    func twoTimesCantBeOneEvent(text: String) {
        #expect(read(text) == .severalTimes)
    }

    @Test(arguments: ["", "   "])
    func nothingAtAll(text: String) {
        #expect(read(text) == .noTime)
    }

    @Test(arguments: ["fri 3pm", "3pm", "tomorrow at noon", "at 3pm on friday", "on fri at 3pm"])
    func aTimeNeedsAName(text: String) {
        #expect(read(text) == .noTitle)
    }

    // MARK: A time that's gone

    @Test(arguments: ["dentist today 9am", "dentist 9am today", "today dentist 9am", "dentist wed 9am", "dentist nov 4 9am", "dentist 2026-11-04 9am",
                      "dentist 2026-01-05 3pm", "dentist yesterday 3pm", "dentist last fri 3pm"])
    func aTimeThatsGoneIsSaid(text: String) {
        #expect(isPast(read(text)))
    }

    @Test func todaysWeekdayMeansTodayWhileTheTimeIsAhead() {
        let friday = moment("2026-11-06 10:00")
        #expect(event("dentist fri 3pm", at: friday)?.start == moment("2026-11-06 15:00"))
        #expect(event("fri dentist 3pm", at: friday)?.start == moment("2026-11-06 15:00"))
    }

    @Test func aWeekdayThatsPassedTodayIsSaidRatherThanMovedOn() {
        #expect(isPast(read("dentist fri 3pm", at: moment("2026-11-06 16:00"))))
    }

    @Test func midnightOnTheDayItsTypedIsTonight() {
        #expect(event("call fri midnight", at: moment("2026-11-06 22:00"))?.start == moment("2026-11-07 00:00"))
    }

    @Test func nextMeansTheWeekAfterThisOne() {
        let sunday = moment("2026-11-08 10:00")
        #expect(event("dentist next fri 3pm")?.start == moment("2026-11-13 15:00"))
        #expect(event("dentist next fri 3pm", at: sunday)?.start == moment("2026-11-20 15:00"))
        var mondayFirst = calendar()
        mondayFirst.firstWeekday = 2
        guard case .event(let event) = EventText.read("dentist next fri 3pm", now: sunday, calendar: mondayFirst) else {
            Issue.record("It should have read that")
            return
        }
        #expect(event.start == moment("2026-11-13 15:00"))
    }

    /// The names and numbers mean what they mean, whichever calendar the Mac uses.
    @Test(arguments: [Calendar.Identifier.islamicCivil, .hebrew, .persian, .chinese, .buddhist])
    func anotherCalendar(identifier: Calendar.Identifier) {
        var other = Calendar(identifier: identifier)
        other.timeZone = TimeZone(identifier: "Asia/Karachi")!
        #expect(EventText.read("dentist 25 dec 3pm", now: now, calendar: other)
            == .event(NewEvent(title: "dentist", start: moment("2026-12-25 15:00"), end: moment("2026-12-25 16:00"))))
        #expect(EventText.read("dentist fri 3pm", now: now, calendar: other)
            == .event(NewEvent(title: "dentist", start: moment("2026-11-06 15:00"), end: moment("2026-11-06 16:00"))))
    }
}

/// The row, with a stand-in for the calendar that never reaches the real one. It reads from a moment
/// fixed on this Mac's clock, a Wednesday at 10:00, so what passes doesn't depend on when it runs.
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
    private let now = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 10))!

    init() {
        SnapshotRenderer.useScratchDefaults()
        viewModel = NotchViewModel(geometry: NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                                           closedSize: CGSize(width: 186, height: 37), hasHardwareNotch: true))
    }

    private func row(_ body: String) -> CommandResult { CommandEngine.event(body, calendar: calendar, now: now) }

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

    @Test(arguments: ["dentist", "dentist fri", "fri 3pm", "dentist 3pm", "dentist in 2 hours", "dentist tomorrow 3pm and gym fri 4pm", "dentist 3:30",
                      "dentist tomorow 3pm", "dentist nov 31 3pm", "focus until 3pm", "call est 3pm", "meeting fri 3pm for 3 days", "black friday sale 9am"])
    func returnAddsNothingWhenItCantRead(text: String) {
        let row = row(text)
        #expect(row.action == nil)
        viewModel.run(row)
        #expect(calendar.added.isEmpty)
    }

    @Test func itSaysWhatsMissing() {
        #expect(row("dentist fri").title == "No time in that yet")
        #expect(row("dentist 3pm").title == "No day in that yet")
        #expect(row("dentist 3pm").hint == "today 3pm")
        #expect(row("fri 3pm").title == "An event needs a name")
        #expect(row("dentist tomorrow 3pm and gym fri 4pm").title == "That reads as more than one time")
        #expect(row("").title == "Add an event")
        #expect(row("").action == nil)
        #expect(row("dentist 3:30").title == "Add am or pm to the time")
        #expect(row("dentist fri with sam 3pm").title == "Can't read the day in that")
        #expect(row("dentist nov 31 3pm").title == "There's no such date")
        #expect(row("focus until 3pm").title == "Say when it starts")
        #expect(row("call est 3pm").title == "Can't read the time zone in that")
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

    @Test func aTimeThatsGoneAddsNothing() {
        let later = CommandEngine.event("dentist today 3pm", calendar: calendar, now: now.addingTimeInterval(6 * 3600))
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
        #expect(CommandEngine.results(for: "cal dentist tomorrow 3pm", in: viewModel).first?.id == "cal")
        #expect(CommandEngine.results(for: "calendar dentist tomorrow 3pm", in: viewModel).first?.id == "cal")
        #expect(CommandEngine.results(for: "cal", in: viewModel).first?.id == "cal")
    }

    @Test func aReadableEventSpeaksForTheLine() {
        CalendarService.shared.loadSample(events: [], reminders: [])
        #expect(!CommandEngine.results(for: "cal standup tomorrow 9am 30m", in: viewModel).map(\.id).contains("timer"))
    }

    /// Return on the top row would have started a timer called "cal dentist".
    @Test(arguments: ["cal tea 4m", "cal dentist 3:30", "cal dentist fri at 5", "cal standup mon 9", "cal drinks tonight 8", "cal dentist nov 31 3pm",
                      "cal meeting fri 3pm for 3 days", "cal laundry 45"])
    func anUnreadEventDoesntBecomeATimer(text: String) {
        CalendarService.shared.loadSample(events: [], reminders: [])
        let results = CommandEngine.results(for: text, in: viewModel)
        #expect(!results.map(\.id).contains("timer"))
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
