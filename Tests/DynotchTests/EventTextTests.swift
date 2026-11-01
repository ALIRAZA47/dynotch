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
        ("standup tue 09:30", "standup", "2026-11-10 09:30"), ("standup tue 09.30", "standup", "2026-11-10 09:30"),
        ("night shift sat 22:00", "night shift", "2026-11-07 22:00"), ("night shift sat 00:30", "night shift", "2026-11-07 00:30"),
        ("dentist fri at 3pm", "dentist", "2026-11-06 15:00"), ("dentist fri at 15", "dentist", "2026-11-06 15:00"),
        ("dentist fri @ 3pm", "dentist", "2026-11-06 15:00"), ("dentist fri, 3pm", "dentist", "2026-11-06 15:00"),
        ("dentist sun. 3pm", "dentist", "2026-11-08 15:00"), ("dentist sun @ 3pm", "dentist", "2026-11-08 15:00"),
        ("dentist on friday at 3pm", "dentist", "2026-11-06 15:00"), ("dentist, fri 3pm", "dentist", "2026-11-06 15:00"),
        ("dentist 3pm fri", "dentist", "2026-11-06 15:00"), ("dentist 3pm on fri", "dentist", "2026-11-06 15:00"),
        ("drinks fri noon", "drinks", "2026-11-06 12:00"), ("drinks tomorrow at noon", "drinks", "2026-11-05 12:00"),
        ("lunch fri 12 noon", "lunch", "2026-11-06 12:00"), ("call fri midnight", "call", "2026-11-07 00:00"),
        ("dentist (fri 3pm)", "dentist", "2026-11-06 15:00"), ("dentist fri 3pm.", "dentist", "2026-11-06 15:00"),
        ("workshop for 1 hour 9 am fri", "workshop", "2026-11-06 09:00"),
    ])
    func waysOfSayingWhen(text: String, title: String, start: String) {
        #expect(event(text)?.title == title)
        #expect(event(text)?.start == moment(start))
    }

    @Test(arguments: [
        ("dentist today 3pm", "2026-11-04 15:00"), ("dentist 3pm today", "2026-11-04 15:00"), ("dentist tomorrow 3pm", "2026-11-05 15:00"),
        ("dentist tmrw 3pm", "2026-11-05 15:00"), ("dentist tmr 3pm", "2026-11-05 15:00"), ("dentist tmw 3pm", "2026-11-05 15:00"),
        ("drinks tonight 8pm", "2026-11-04 20:00"), ("drinks tonight at 8", "2026-11-04 20:00"), ("drinks tonight 8:30", "2026-11-04 20:30"),
        ("call this afternoon 3pm", "2026-11-04 15:00"), ("drinks this evening 7pm", "2026-11-04 19:00"), ("meeting this morning 11am", "2026-11-04 11:00"),
        ("dentist next fri 3pm", "2026-11-13 15:00"), ("dentist this fri 3pm", "2026-11-06 15:00"), ("dentist next wed 3pm", "2026-11-11 15:00"),
        ("dentist this coming fri 3pm", "2026-11-06 15:00"), ("party 25 dec 9pm", "2026-12-25 21:00"), ("party dec 25 9pm", "2026-12-25 21:00"),
        ("party 25th of december 9pm", "2026-12-25 21:00"), ("party dec 25th 9pm", "2026-12-25 21:00"), ("party dec. 25 9pm", "2026-12-25 21:00"),
        ("party the 25th of dec 9pm", "2026-12-25 21:00"), ("party 25 dec 2027 9pm", "2027-12-25 21:00"), ("party dec 25, 2027 9pm", "2027-12-25 21:00"),
        ("party 2026-12-25 9pm", "2026-12-25 21:00"), ("party 2026/12/25 9pm", "2026-12-25 21:00"), ("party 2027-1-5 9pm", "2027-01-05 21:00"),
        ("party 1 jan 9pm", "2027-01-01 21:00"), ("party 4 nov 9pm", "2026-11-04 21:00"), ("dentist oct 4 3pm", "2027-10-04 15:00"),
        ("drinks friday night 8pm", "2026-11-06 20:00"), ("dentist monday morning at 9", "2026-11-09 09:00"), ("call fri afternoon at 3", "2026-11-06 15:00"),
        ("dinner sat evening at 7", "2026-11-07 19:00"), ("drinks fri night at 8", "2026-11-06 20:00"), ("run sat morning 8am", "2026-11-07 08:00"),
    ])
    func whichDay(text: String, start: String) {
        #expect(event(text)?.start == moment(start))
    }

    /// A weekday beside a date is there to check it. These were moved to the coming Sunday or Friday.
    @Test(arguments: [
        ("dentist sun nov 8 3pm", "2026-11-08 15:00"), ("dentist sunday 8 nov 3pm", "2026-11-08 15:00"), ("dentist fri nov 13 3pm", "2026-11-13 15:00"),
        ("dentist friday 13th 3pm", "2026-11-13 15:00"), ("dentist friday the 13th 3pm", "2026-11-13 15:00"),
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

    /// Past midnight, a night is still the night it was named for.
    @Test(arguments: [
        ("party fri night 1am", "2026-11-07 01:00"), ("party tomorrow night 1am", "2026-11-06 01:00"), ("party fri night 12am", "2026-11-07 00:00"),
        ("party tonight 1am", "2026-11-05 01:00"), ("party tonight 12am", "2026-11-05 00:00"),
    ])
    func theSmallHoursOfANight(text: String, start: String) {
        #expect(event(text)?.start == moment(start))
    }

    @Test func tonightInTheSmallHoursIsThisNight() {
        #expect(event("party tonight 1am", at: moment("2026-11-04 00:30"))?.start == moment("2026-11-04 01:00"))
    }

    @Test func numbersInATitleStayInIt() {
        #expect(event("1:1 with sam fri 3pm")?.title == "1:1 with sam")
        #expect(event("sprint 12 review tue 2pm")?.title == "sprint 12 review")
        #expect(event("call 555-1234 fri at 3pm")?.title == "call 555-1234")
        #expect(event("review pr 17 mon 10:30am")?.title == "review pr 17")
        #expect(event("version 2.15 review fri 3pm")?.title == "version 2.15 review")
        #expect(event("pay 15.50 fri 3pm")?.title == "pay 15.50")
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
        "catch up next fri 3pm", "year end fri 3pm", "west end fri 8pm", "race finish sat 3pm", "project end fri 5pm", "see dr tomorrow 3pm",
        "appointment with dr today 3pm", "call ash fri 3pm", "wear black sat 3pm", "fashion week fri 3pm", "electrician coming tue 9-11am",
        "high noon fri 8pm", "midnight mass dec 24 11pm", "story time fri 3pm", "weekly sync fri 3pm", "swim 400m fri 7am",
        "flowers for mom fri 3pm",
    ])
    func aTitleStaysAsTyped(text: String) throws {
        let title = try #require(event(text)?.title)
        #expect(text.hasPrefix(title))
    }

    // MARK: Zones

    /// The time is the one there, and the day is the one on this calendar.
    @Test(arguments: [
        ("call fri 3pm pst", "America/Los_Angeles"), ("call fri 3pm est", "America/New_York"), ("call fri 3pm EST", "America/New_York"),
        ("call fri 3pm Est", "America/New_York"), ("call fri 3pm ist", "Asia/Kolkata"), ("call fri 3pm pkt", "Asia/Karachi"),
        ("call fri 3pm sgt", "Asia/Singapore"), ("call fri 3pm aest", "Australia/Sydney"), ("call fri 3pm cet", "Europe/Paris"),
        ("call fri 3pm lahore time", "Asia/Karachi"), ("call fri 3pm new york time", "America/New_York"), ("call fri 3pm new york time.", "America/New_York"),
        ("call fri 3pm nyc time", "America/New_York"), ("call fri 3pm sf time", "America/Los_Angeles"), ("call fri 3pm tokyo time", "Asia/Tokyo"),
        ("call fri 3pm eastern time", "America/New_York"), ("call fri 3pm pacific time", "America/Los_Angeles"), ("call fri 3pm central time", "America/Chicago"),
        ("call fri 3pm mountain time", "America/Denver"), ("call fri 3pm hawaii time", "Pacific/Honolulu"), ("call fri 3pm est time", "America/New_York"),
        ("call fri 3pm gmt time", "GMT"), ("call 3pm est fri", "America/New_York"), ("call 3pm est on fri", "America/New_York"),
        ("call fri 3pm (est)", "America/New_York"), ("call fri 3pm [est]", "America/New_York"), ("call fri 3pm e.s.t.", "America/New_York"),
        ("call fri 3pm sast", "Africa/Johannesburg"), ("call fri 3pm npt", "Asia/Kathmandu"), ("call fri 3pm wita", "Asia/Makassar"),
        ("call fri 3pm azt", "Asia/Baku"), ("call fri 3pm nzt", "Pacific/Auckland"),
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
    @Test(arguments: ["call fri 3pm est", "call fri 3pm new york time", "call 3pm est fri"])
    func aZoneDoesntPushTheDayToNextWeek(text: String) {
        let friday = moment("2026-11-06 10:00")
        #expect(event(text, at: friday)?.start == moment("2026-11-06 15:00", in: "America/New_York"))
        #expect(event(text, at: friday)?.start == moment("2026-11-07 01:00"))
    }

    /// These could be zones or could be part of the name, and the hour would be wrong either way.
    @Test(arguments: [
        "gym fri 6pm pt", "gym fri 6pm PT", "call fri 3pm et", "call fri 3pm ET", "class fri 3pm ART", "hospital fri 3pm CT", "pay fri 3pm gst",
        "exam mon 9am ict", "class fri 3pm ict", "review fri 3pm bst", "clinic fri 3pm trt", "VET FRI 3PM CAT", "dentist fri 3pm art", "vet fri 3pm cat",
        "call fri 3pm ast", "call fri 3pm et/pt", "call fri 3pm gmt+5", "call est 3pm", "call pkt fri 3pm", "call lahore time 3pm", "call new york time fri 3pm",
    ])
    func aZoneThatCantBeReadIsSaid(text: String) {
        #expect(read(text) == .unclearZone)
    }

    // MARK: The shape of a line

    /// In each of these a word was taken for the day, or the day was taken from the title.
    @Test(arguments: [
        "tomorrow call sam 5pm", "fri dentist 3pm", "monday standup 9am", "mon dentist 3pm", "next friday team lunch 1pm", "friday dinner with anna at 8pm",
        "dec 25 lunch at noon", "25 dec party 9pm", "today dentist 3pm", "tonight dentist 3pm", "tomorrow's standup 9am", "tonight's dinner 8pm", "sunday brunch 11am",
        "on fri dentist 3pm", "fri night date 8pm", "SAT prep 3pm", "sun cream shop 3pm", "Sun Life meeting 3pm", "sat nav fitting 3pm", "mon ami dinner 8pm",
        "Tomorrow Never Dies 8pm", "may 5 people come 3pm", "saturday night live 11pm", "fri night lights 8pm", "fri nightmare 3pm", "fri nights 8pm",
        "sat mornings 9am", "tomorrow nightclub 11pm", "dentist fri with sam 3pm", "lunch tomorrow with sam at 1pm", "dinner friday with anna 8pm",
        "dentist fri around 3pm", "dentist fri 13 3pm", "fri 13 dentist 3pm", "fri 13th dentist 3pm", "dentist fri 11/13 3pm", "dentist tuesday week 3pm",
        "dentist fri week 3pm", "fri week dentist 3pm", "friday after next dentist 3pm", "dentist the friday after next 3pm",
        "dentist first monday of december 3pm", "black friday sale 9am", "good friday service 10am", "easter sunday lunch 1pm", "meet fri bis 3pm",
    ])
    func aDayApartFromTheTimeIsSaid(text: String) {
        #expect(read(text) == .dayApart)
    }

    @Test(arguments: [
        "fri 3pm dentist", "call fri 3pm with sam", "dentist 3pm with sam fri", "lunch 1pm sun terrace", "meet fri 3pm sgt jones", "pay fri 3pm gst return",
        "train fri 9am central station", "hospital fri 3pm CT scan", "dentist fri 3pm art class", "meet fri 3pm central park", "drinks fri 6pm pacific beach",
        "lunch fri 1pm eastern market", "meet fri 3pm london bridge", "visit fri 3pm mountain view", "trip fri 9am atlantic city", "fri 3pm PT session",
        "fri 3pm est dentist", "call fri 3pm with sam pst", "call fri 3pm sam est", "webinar fri 3pm us eastern", "call fri 3pm in est", "call fri 3pm eastern",
        "call fri 3pm pacific", "call fri 3pm lahore", "call fri 3pm idt", "call fri 3pm myt", "call fri 3pm zulu", "call fri 3pm +0500",
        "call fri 3pm central european time", "call fri 3pm aus time", "swim fri 7am 400m", "sprint fri 7am 100m", "dentist fri 3pm week", "dentist fri 3pm in december",
        "dentist fri 9am after christmas", "dentist fri 3pm of december", "dentist 3pm fri 13", "dentist fri 3pm weekly",
        "block fri 2pm focus time", "fri 3pm family time", "fri 7pm game time", "vet fri 3pm cat time", "kids fri 3pm pet time", "class fri 3pm art time",
        "gym fri 6pm pt time", "fri 3pm cat-sitting", "fri 3pm art-class",
    ])
    func wordsAfterTheTimeAreSaid(text: String) {
        #expect(read(text) == .titleLast)
    }

    // MARK: Length

    @Test(arguments: [
        ("standup mon 9am 30m", 1800), ("standup mon 9am 30 min", 1800), ("standup mon 9am for 15 min", 900), ("workshop fri 9am for 2 hours", 7200),
        ("workshop fri 9am 2h", 7200), ("offsite fri 9am 1h30", 5400), ("offsite fri 9am 1.5 hours", 5400), ("offsite fri 9am 1,5 hours", 5400),
        ("for 45 minutes review fri 2pm", 2700), ("offsite fri 9am 90m", 5400), ("offsite fri 9am 120 minutes", 7200), ("workshop for 1 hour 9 am fri", 3600),
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
        ("standup fri 09:00-09:30", 1800), ("meeting fri 09:00-17:00", 28800), ("meeting fri 9:00-17:00", 28800), ("party sat 9pm-2am", 18000),
        ("dentist fri 3-4pm", 3600), ("work fri 9-5pm", 28800), ("party fri 9pm-midnight", 10800), ("lunch fri noon-2pm", 7200), ("lunch fri 11-1pm", 7200),
        ("lunch fri 11:30-1pm", 5400), ("lunch fri 12-2pm", 7200), ("night shift fri 7pm-7am", 43200), ("party fri night 1am-3am", 7200),
        ("meeting fri 03:00-04:00pm", 3600), ("meeting fri 03:00 - 04:00 PM", 3600), ("class mon 06-07pm", 3600), ("town hall tue 09:30-10:30 PM", 3600),
    ] as [(String, TimeInterval)])
    func aRangeSetsTheLength(text: String, seconds: TimeInterval) {
        #expect(length(text) == seconds)
    }

    @Test func aRangeStartsWhenItSays() {
        #expect(event("lunch fri 11-1pm")?.start == moment("2026-11-06 11:00"))
        #expect(event("lunch fri 12-1pm")?.start == moment("2026-11-06 12:00"))
        #expect(event("work fri 9-5pm")?.start == moment("2026-11-06 09:00"))
        #expect(event("party sat 9pm-2am")?.start == moment("2026-11-07 21:00"))
        #expect(event("party fri night 1am-3am")?.start == moment("2026-11-07 01:00"))
        #expect(event("meeting fri 03:00-04:00pm")?.start == moment("2026-11-06 15:00"))
        #expect(event("town hall tue 09:30-10:30 PM")?.start == moment("2026-11-10 21:30"))
    }

    /// The clocks go back at 2:00 that night, so 10pm to 6am is nine hours and still ends at six.
    @Test func aRangeEndsOnTheClock() {
        let newYork = calendar(in: "America/New_York")
        let reading = EventText.read("late shift sat 10pm-6am", now: moment("2026-10-29 10:00", in: "America/New_York"), calendar: newYork)
        #expect(reading == .event(NewEvent(title: "late shift", start: moment("2026-10-31 22:00", in: "America/New_York"),
                                           end: moment("2026-11-01 06:00", in: "America/New_York"))))
        #expect(moment("2026-11-01 06:00", in: "America/New_York").timeIntervalSince(moment("2026-10-31 22:00", in: "America/New_York")) == 9 * 3600)
    }

    @Test func aTypedLengthBeatsARange() {
        #expect(length("meeting fri 3pm to 5pm for 30 min") == 1800)
    }

    @Test func aLengthAtTheFrontIsPartOfTheName() {
        #expect(event("2h workshop fri 3pm")?.title == "2h workshop")
        #expect(length("2h workshop fri 3pm") == 3600)
    }

    @Test(arguments: [
        ("meeting fri 3pm for an hour", 3600), ("meeting fri 3pm for half an hour", 1800), ("meeting fri 3pm for an hour and a half", 5400),
        ("meeting fri 3pm for 1 hour and 30 minutes", 5400), ("meeting fri 3pm 1 hour and 30 minutes", 5400), ("standup for 30 min 9:30am mon", 1800),
        ("standup for 1h 9:30am mon", 3600), ("standup mon 9am for 15m", 900),
    ] as [(String, TimeInterval)])
    func lengthsInWords(text: String, seconds: TimeInterval) {
        #expect(length(text) == seconds)
        #expect(event(text)?.title == (text.hasPrefix("standup") ? "standup" : "meeting"))
    }

    @Test(arguments: ["meeting fri 3pm for 3 days", "meeting fri 3pm for 25 hours", "meeting for 2 weeks fri 3pm", "trip fri 9am 3 days", "meeting fri 3pm for two hours",
                      "meeting fri 3pm for thirty minutes", "meeting fri 3pm two hours", "meeting for two hours fri 3pm", "standup 30m mon 9am", "standup 30 min mon 9am",
                      "meeting fri 3pm for 2 1/2 hours", "pitch for 5m round fri 3pm", "invoice for 5m fri 3pm", "loan for 2m mon 9am"])
    func aLengthItCantUseIsSaid(text: String) {
        #expect(read(text) == .unclearLength)
    }

    @Test func aForThatIsntALengthStays() {
        #expect(event("team lunch for 2 fri 1pm")?.title == "team lunch for 2")
        #expect(event("flowers for mom fri 3pm")?.title == "flowers for mom")
    }

    // MARK: What it won't guess

    @Test(arguments: [
        "dentist", "dentist fri", "friday", "fri", "lunch fri", "lunch tomorrow", "sunday brunch", "dentist friday 3", "tomorrow 9", "dentist 5",
        "25 dec", "dentist 25 dec", "dentist next week", "standup 30m", "for 2 hours", "walk tomorrow morning", "dinner tonight", "drinks tonight 8",
        "call tomorrow morning 10", "call fri morning 10", "drinks this evening", "party 25.12.2026", "party 25.12.26", "party on 25.12.2026",
        "party 31.12.2026", "party 12.25.2026", "party 2026.11.05", "party 2026/11/05", "dentist at 2026-11-05", "dentist 13pm", "dentist fri 0pm",
        "dentist fri 25:00", "dentist fri 3:75pm", "party tonight at 0", "dentist fri 4.15", "dentist fri 3-4", "dinner fri 7-9", "visit apt 5a fri", "room 3p fri",
        "unit 7a mon", "pay $15.50 fri", "pay €20.00 today", "pay 19.50 fri", "tip 20.00 tomorrow", "version 13.10 fri", "release 14.20 tomorrow", "dentist fri 3:٣٠pm",
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
        "mother's day lunch 1pm", "labor day bbq 1pm", "dentist 5th 3pm", "dentist the fifth 3pm", "dentist febuary 3 3pm", "dentist novmber 3 3pm",
        "dentist in three days 3pm", "dentist in four weeks 3pm", "dentist in 2 wks 3pm", "dentist in a few days 3pm", "dentist 3 days later 3pm",
        "dentist end of month 3pm", "party 25.12. 9pm", "dentist 11/13 3pm", "dentist 11/31 3pm", "dentist 2/30 3pm", "dentist 31/11 3pm", "dentist 11-13 3pm", "24/7 support sync 3pm",
        "sprint 11/12 review 3pm", "leave mon-fri 9am", "trip fri-sun 8am", "conference nov 5-7 9am", "call dom 3pm", "lunch with dom 1pm", "call sab 3pm", "up next 3pm",
        "dentist @ 3pm", "lunch with frida 1pm", "sundae party 3pm", "call june 3pm",
    ])
    func aTimeAloneIsntAnEvent(text: String) {
        #expect(read(text) == .noDay)
    }

    /// These come out the same whatever day and hour they're typed.
    @Test(arguments: ["dentist 3:30", "dentist 1:00", "dentist 9:30", "dentist 10:30", "dentist 12:30", "dentist fri at 7", "call mon at 8", "call fri at 3",
                      "dentist at 5", "party tonight at 1", "party tonight at 2", "party tonight at 12", "party sat 9-2am", "party sat 8-1am", "party sat 10-2am",
                      "night shift fri 10-6am", "gym fri 12-1am", "dentist fri 3pm-5", "lunch fri 9-noon", "meeting fri 3-2pm", "meeting fri 1-12pm",
                      "party sat 8-12pm", "workshop sat 9-12pm", "qawwali night fri 9-12pm", "mehndi 4 dec 8-12pm", "meeting fri 04:00-02:00pm", "meeting fri 1:00-14:00",
                      "meeting fri 3:00-15:00", "table 4 - 8pm sat", "gate 12 - 5pm fri", "room 5 - 3pm fri", "apollo 13 - 3pm fri", "table 4 to 8pm sat", "dentist 3-4pm fri"])
    func aTimeThatCouldBeEitherAsksWhich(text: String) {
        #expect(read(text) == .needsAMOrPM)
    }

    @Test(arguments: [
        "dentist 2nd fri 3pm", "dentist second fri 3pm", "dentist after tomorrow 3pm", "dentist day after tomorrow 3pm", "every friday 3pm dentist", "call every fri 3pm",
        "call fri 3pm every week", "dentist fri 3pm next week", "dentist next week fri 3pm", "dentist fri 3pm in 2 weeks", "dentist fortnight fri 3pm", "lunch with sun 1pm",
        "call mr sun 3pm", "dentist the friday 3pm", "dentist a week from friday 3pm", "dentist the following fri 3pm", "what's next fri 3pm", "sale black friday 9am",
        "service good friday 10am", "lunch easter sunday 1pm", "sale cyber monday 9am", "dentist 2030 dec 25 3pm", "dentist last dec 5 3pm", "party next nov 13 9pm",
        "bbq bank holiday monday 2pm", "picnic easter monday 10am", "fair whit monday 10am", "service holy saturday 8pm", "giving tuesday 9am", "shop small business saturday 9am",
        "dentist a week today 3pm", "dentist a week on fri 3pm", "dentist week from today 3pm", "dentist ten days from today 3pm", "dentist a week tomorrow 3pm",
        "dentist two weeks on friday 3pm", "brunch next weekend sat 11am", "dentist following week fri 3pm", "dentist in a couple of weeks fri 3pm",
        "dentist in a few weeks fri 3pm", "dentist in ten days fri 3pm", "dentist in december fri 3pm", "trip in january mon 9am", "dentist late nov fri 3pm",
        "gym weekly mon 7am", "dentist fortnightly fri 3pm", "standup daily mon 9am", "review 6 months fri 3pm", "sprint 2 weeks fri 3pm", "tutor SAT 3pm",
        "take SAT dec 5 8am", "call dr. sun 3pm", "dentist fri 3pm the week after",
        "drinks fri night 9am", "meeting tomorrow morning 5pm", "call tonight 12pm", "dentist tonight 3pm",
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

    @Test(arguments: ["focus fri until 3pm", "work fri until 5pm", "work until 5pm fri", "call till 4pm", "meeting ends 3pm", "meeting fri ends at 3pm",
                      "call end 3pm", "workshop finishes 5pm", "shift ending 6pm", "drinks after 8pm fri", "drinks fri before 8pm", "work to 5pm fri", "on call through 5pm fri",
                      "away thru 5pm fri", "work up to 5pm fri", "dinner half past 7pm fri", "meeting quarter past 3pm fri", "meeting quarter to 3pm fri", "meeting 10 past 3pm fri"])
    func anEndAloneIsntAStart(text: String) {
        #expect(read(text) == .noStart)
    }

    /// FX11: "in 2 hours" isn't read by `ReminderText` either, and `cal` is safe without it.
    @Test func aRelativeTimeIsntReadYet() {
        #expect(read("dentist in 2 hours") == .noTime)
        #expect(read("dentist in 30 minutes") == .noTime)
    }

    @Test(arguments: ["dentist tomorrow 3pm and gym fri 4pm", "review 10:30 fri 3pm", "meeting fri 3pm-2pm", "meeting fri 11pm-1pm", "fri 3pm to fri 5pm dentist",
                      "offsite sat 9am to sun 5pm", "leave mon to fri 9am", "standup mon to fri 9am", "conference mon to wed 9am", "sat exam fri 9am", "dentist fri or sat 3pm",
                      "dentist fri 3pm tomorrow", "dentist between 3 and 5pm fri", "dentist 3 or 4pm fri", "dentist 3, 4pm fri", "5, 6 dec 3pm", "conference 5 to 7 dec 9am"])
    func twoTimesCantBeOneEvent(text: String) {
        #expect(read(text) == .severalTimes)
    }

    @Test(arguments: ["", "   "])
    func nothingAtAll(text: String) {
        #expect(read(text) == .noTime)
    }

    @Test(arguments: ["fri 3pm", "3pm", "tomorrow at noon", "at 3pm on friday", "on fri at 3pm", "& fri 3pm"])
    func aTimeNeedsAName(text: String) {
        #expect(read(text) == .noTitle)
    }

    // MARK: A time that's gone

    @Test(arguments: ["dentist today 9am", "dentist 9am today", "dentist wed 9am", "dentist nov 4 9am", "dentist 2026-11-04 9am", "dentist 2026-01-05 3pm",
                      "dentist yesterday 3pm", "dentist last fri 3pm", "dentist nov 3 3pm", "dentist nov 1 3pm", "party oct 31 9pm", "dentist 2 nov 3pm",
                      "dentist tue nov 3 3pm", "dentist oct 5 3pm"])
    func aTimeThatsGoneIsSaid(text: String) {
        #expect(isPast(read(text)))
    }

    @Test func todaysWeekdayMeansTodayWhileTheTimeIsAhead() {
        #expect(event("dentist fri 3pm", at: moment("2026-11-06 10:00"))?.start == moment("2026-11-06 15:00"))
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
                      "dentist tomorow 3pm", "dentist nov 31 3pm", "focus until 3pm", "call est 3pm", "meeting fri 3pm for 3 days", "black friday sale 9am",
                      "fri dentist 3pm", "fri 3pm dentist", "SAT prep 3pm"])
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
        #expect(row("sale black friday 9am").title == "Can't read the day in that")
        #expect(row("dentist fri with sam 3pm").title == "Put the day beside the time")
        #expect(row("fri 3pm dentist").title == "Put the name first")
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
