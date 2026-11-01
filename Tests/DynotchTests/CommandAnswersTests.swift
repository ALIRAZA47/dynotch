import AppKit
import Foundation
import Testing
@testable import Dynotch

private let pakistan = TimeZone(identifier: "Asia/Karachi")!
private let english = Locale(identifier: "en_US")

/// What's formatted has a narrow space before AM and PM.
private func plain(_ text: String?) -> String? { text?.replacingOccurrences(of: "\u{202F}", with: " ") }

private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

struct WorldTimeTests {
    /// 23:00 in Lahore, 11:00 in Los Angeles, on a Saturday.
    private let now = date("2026-10-31T18:00:00Z")

    private func answer(_ text: String, now: Date? = nil) -> String? {
        plain(WorldTime.answer(text, now: now ?? self.now, here: pakistan, locale: english)?.text)
    }

    @Test func theExampleFromThePage() {
        #expect(answer("5pm pst in lahore") == "5:00 PM PDT = 5:00 AM Sun in Lahore")
    }

    @Test func initialsMeanTheZonesClockAndSaySoInWinter() {
        #expect(answer("5pm pst in lahore", now: date("2026-12-15T12:00:00Z")) == "5:00 PM PST = 6:00 AM Wed in Lahore")
        #expect(answer("5pm pdt in lahore", now: date("2026-12-15T12:00:00Z")) == "5:00 PM PST = 6:00 AM Wed in Lahore")
    }

    @Test func aCityOnEachSide() {
        #expect(answer("3pm london to tokyo") == "3:00 PM in London = 12:00 AM Sun in Tokyo")
        #expect(answer("17:30 lahore in utc") == "5:30 PM in Lahore = 12:30 PM UTC")
    }

    @Test func withNoPlaceItMeansHere() {
        #expect(answer("noon in nyc") == "12:00 PM here = 3:00 AM in NYC")
        #expect(answer("9am in lahore") == "9:00 AM here = 9:00 AM in Lahore")
    }

    @Test func theTimeThereNow() {
        #expect(answer("time in tokyo") == "3:00 AM Sun in Tokyo")
        #expect(answer("tokyo time") == "3:00 AM Sun in Tokyo")
        #expect(answer("now in london") == "6:00 PM in London")
        #expect(answer("new york time") == "2:00 PM in New York")
    }

    @Test func wordsForTimes() {
        #expect(answer("midnight in tokyo") == "12:00 AM here = 4:00 AM in Tokyo")
        #expect(answer("noon tokyo in lahore") == "12:00 PM in Tokyo = 8:00 AM in Lahore")
    }

    @Test func hoursThatChangeMeaning() {
        #expect(answer("12am in lahore") == "12:00 AM here = 12:00 AM in Lahore")
        #expect(answer("12pm in lahore") == "12:00 PM here = 12:00 PM in Lahore")
        #expect(answer("5 pm in lahore") == "5:00 PM here = 5:00 PM in Lahore")
        #expect(answer("5:45p in lahore") == "5:45 PM here = 5:45 PM in Lahore")
    }

    @Test func initialsMacOSCantSpellStayAsTyped() {
        #expect(answer("9am jst in lahore") == "9:00 AM JST = 5:00 AM in Lahore")
    }

    @Test func caseDoesntMatter() {
        #expect(answer("5PM PST IN Lahore") == "5:00 PM PDT = 5:00 AM Sun in Lahore")
    }

    @Test func whatsCopiedIsTheAnswer() {
        let value = WorldTime.answer("5pm pst in lahore", now: now, here: pakistan, locale: english)?.value
        #expect(plain(value) == "5:00 AM Sun")
    }

    /// A zone that changes its clocks says which side it's on, whatever was typed.
    @Test func theOffsetUsedIsTheOneShown() {
        #expect(answer("3pm cet in lahore", now: date("2026-07-15T12:00:00Z")) == "3:00 PM GMT+2 = 6:00 PM in Lahore")
        #expect(answer("3pm cest in lahore", now: date("2026-11-15T12:00:00Z")) == "3:00 PM GMT+1 = 7:00 PM in Lahore")
    }

    @Test func zonesThatChangeClocksOnDifferentDays() {
        // New York changes a week after London, so the gap is an hour short that week.
        #expect(answer("9am new york in london", now: date("2026-10-28T12:00:00Z")) == "9:00 AM in New York = 1:00 PM in London")
        #expect(answer("9am new york in london", now: date("2026-11-04T12:00:00Z")) == "9:00 AM in New York = 2:00 PM in London")
    }

    @Test(arguments: ["5 in lahore", "13pm in lahore", "0am in lahore", "25:00 in lahore", "12:99 in tokyo", "5pm in atlantis",
                      "tea in lahore", "time in nowhere", "5pm nowhere in lahore", "lahore", "5pm", "time", "san francisco to tokyo",
                      "9am to 5pm in lahore", "time to eat", "time to art", "time to pet", "now to tokyo"])
    func whatIsntATimeSomewhere(text: String) {
        #expect(answer(text) == nil)
    }

    @Test func everyCityInTheTableIsAPlace() {
        for (_, names) in WorldTime.cities {
            for name in names { #expect(WorldTime.place(name)?.name == name) }
        }
    }

    @Test func citiesMacOSNamesAZoneAfterComeForFree() {
        #expect(WorldTime.place("ho chi minh")?.zone.identifier == "Asia/Ho_Chi_Minh")
        #expect(WorldTime.place("BUENOS AIRES")?.name == "Buenos Aires")
    }

    @Test func aClockSaysTheDayOnlyWhenItDiffers() {
        let tokyo = WorldTime.place("tokyo")!, lahore = WorldTime.place("lahore")!, london = WorldTime.place("london")!
        #expect(WorldTime.clock(at: tokyo, on: now, here: pakistan, locale: english).day == "Sun")
        #expect(WorldTime.clock(at: lahore, on: now, here: pakistan, locale: english).day == nil)
        #expect(WorldTime.clock(at: london, on: date("2026-10-31T20:00:00Z"), here: pakistan, locale: english).day == "Sat")
    }
}

struct DateTextTests {
    private let now = date("2026-10-31T09:00:00Z")
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func answer(_ text: String) -> (text: String, value: String)? {
        DateText.answer(text, now: now, calendar: calendar, locale: english)
    }

    @Test func aDateThatWouldReadAsASum() {
        #expect(answer("2026-10-31")?.text == "Saturday, October 31, 2026 · today")
        #expect(answer("2026-10-31")?.value == "Saturday, October 31, 2026")
        #expect(answer("2026/10/31")?.text == "Saturday, October 31, 2026 · today")
    }

    @Test func howFarOffItIs() {
        #expect(answer("2026-11-01")?.text == "Sunday, November 1, 2026 · tomorrow")
        #expect(answer("2026-10-30")?.text == "Friday, October 30, 2026 · yesterday")
        #expect(answer("2026-12-25")?.text == "Friday, December 25, 2026 · in 55 days")
        #expect(answer("2026-01-01")?.text == "Thursday, January 1, 2026 · 303 days ago")
    }

    @Test(arguments: ["2026-13-45", "2026-02-30", "2026-1-5", "10-31", "26-10-31", "20261031", "1500-10-20", "5000-12-20"])
    func aDayThatDoesntExistStaysASum(text: String) {
        #expect(answer(text) == nil)
    }

    /// It would be the year 2569 on a Thai Mac, and nothing at all on an Islamic one, and then a sum.
    @Test(arguments: [Calendar.Identifier.buddhist, .islamicUmmAlQura, .japanese])
    func aDateIsGregorianWhateverTheMacUses(identifier: Calendar.Identifier) {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        #expect(DateText.answer("2026-10-31", now: now, calendar: calendar, locale: english)?.text.hasSuffix("· today") == true)
    }

    @Test(arguments: ["days until 2026-02-30", "days since 2026-13-01", "days until nov 31", "days until feb 30"])
    func aDayThatDoesntExistHasNoCount(text: String) {
        #expect(DateText.answer(text) == nil)
    }

    @Test(arguments: ["days from today to 25 dec", "days from now until 25 dec", "days from 1 jan to 25 dec", "days between 1 jan and 25 dec"])
    func twoDatesArentAnsweredAsOne(text: String) {
        #expect(DateText.answer(text) == nil)
    }

    @Test(arguments: ["days since wedding", "days since wedding 1 oct", "days until 11/31", "days until 2/30", "days until 31.11.2026", "days until 12/25",
                      "days from 1 jan til 25 dec", "days from 1 jan through 25 dec", "days from 1 jan thru 25 dec", "days from 1 jan - 25 dec"])
    func onlyADayOnItsOwnIsCounted(text: String) {
        #expect(answer(text) == nil)
    }

    @Test func todayIsTodayAtAnyHour() {
        for hour in [1, 11, 13, 23] {
            let moment = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now)!
            #expect(DateText.answer("days since 31 oct", now: moment, calendar: calendar, locale: english)?.value == "0")
        }
    }

    @Test func daysToADateWithAYear() {
        #expect(answer("days until 2026-12-25")?.text == "55 days until Fri, Dec 25, 2026")
        #expect(answer("days until 2026-12-25")?.value == "55")
        #expect(answer("how many days until 2026-11-01")?.text == "1 day until Sun, Nov 1, 2026")
        #expect(answer("days since 2026-10-30")?.text == "1 day since Fri, Oct 30, 2026")
        #expect(answer("days until 2026-10-31")?.text == "Sat, Oct 31, 2026 is today")
    }

    @Test func oneThatsGoneCountsBack() {
        #expect(answer("days until 2026-10-01")?.text == "30 days since Thu, Oct 1, 2026")
    }

    @Test func aDayWithNoYearIsTheComingOne() {
        #expect(answer("days until 10 nov")?.value == "10")
        #expect(answer("DAYS UNTIL 10 nov")?.value == "10")
        #expect(answer("how many days until 10 nov?")?.value == "10")
        #expect(answer("days until 30 oct")?.value == "364")
    }

    @Test func lookingBackItsTheLastOne() {
        #expect(answer("days since 28 oct")?.value == "3")
        #expect(answer("days since 1 nov")?.value == "364")
    }

    /// Saturday is today here.
    @Test func aWeekday() {
        #expect(answer("days until friday")?.value == "6")
        #expect(answer("days to next fri")?.value == "6")
        #expect(answer("days since friday")?.value == "1")
        #expect(answer("days since saturday")?.value == "0")
        #expect(answer("days since last sat")?.value == "7")
    }

    @Test func daysAroundToday() {
        #expect(answer("days until tomorrow")?.value == "1")
        #expect(answer("days since yesterday")?.value == "1")
        #expect(answer("days until today")?.value == "0")
    }

    /// Only the year goes first without the zeros, as a sum on its own could read the same.
    @Test func aDateWithoutItsZeros() {
        #expect(answer("days until 2027-1-5")?.value == "66")
        #expect(answer("days since 2026/1/5")?.value == "299")
    }

    @Test(arguments: [Calendar.Identifier.islamicCivil, .hebrew, .persian, .chinese, .buddhist])
    func anotherCalendarCountsTheSame(identifier: Calendar.Identifier) {
        var other = Calendar(identifier: identifier)
        other.timeZone = calendar.timeZone
        #expect(DateText.answer("days until 25 dec", now: now, calendar: other, locale: english)?.value == "55")
    }

    @Test(arguments: ["days", "days until", "days until the weekend", "days of thunder", "day one"])
    func whatItCantRead(text: String) {
        #expect(answer(text) == nil)
    }
}

struct DataSizeTests {
    @Test func thePagesExamples() {
        #expect(UnitConversion.convert("1 gb to mb")?.text == "1 GB = 1000 MB")
        #expect(UnitConversion.convert("1.5 gb to mb")?.value == "1500")
    }

    @Test func aSmallPartOfTheNextUnitUpDoesntRoundAway() {
        #expect(UnitConversion.convert("1 mb to gb")?.value == "0.001")
        #expect(UnitConversion.convert("1 byte to gb")?.value == "0.000000001")
    }

    @Test func binaryUnitsAreTheirOwn() {
        #expect(UnitConversion.convert("1 gb to mib")?.value == "953.674316")
        #expect(UnitConversion.convert("1 gib to mb")?.value == "1073.74182")
    }

    @Test func wordsAndBits() {
        #expect(UnitConversion.convert("8 bits to bytes")?.value == "1")
        #expect(UnitConversion.convert("2 terabytes in gigabytes")?.value == "2000")
        #expect(UnitConversion.convert("100 mbit to mb")?.value == "12.5")
    }

    @Test func aCapitalThenALowercaseBIsBits() {
        #expect(UnitConversion.convert("1 Gb to GB")?.text == "1 Gb = 0.125 GB")
        #expect(UnitConversion.convert("100 Mb to MB")?.value == "12.5")
        #expect(UnitConversion.convert("1 Tb to TB")?.value == "0.125")
        #expect(UnitConversion.convert("100 mb to MB")?.value == "100")
        #expect(UnitConversion.convert("100 MB to GB")?.value == "0.1")
        #expect(UnitConversion.convert("1 Pb to PB")?.value == "0.125")
    }

    @Test func aLoneBBesideACapitalIsABit() {
        #expect(UnitConversion.convert("8 b to B")?.value == "1")
        #expect(UnitConversion.convert("1 B to b")?.value == "8")
        #expect(UnitConversion.convert("1000 b to kb")?.value == "1")
    }

    @Test func aSizeIsntAWeight() {
        #expect(UnitConversion.convert("1 kg to gb") == nil)
    }

    /// The rest still round to two places, as they always did.
    @Test func otherUnitsAreAsTheyWere() {
        #expect(UnitConversion.convert("5 km to mi")?.value == "3.11")
        #expect(UnitConversion.convert("70 f in c")?.value == "21.11")
        #expect(UnitConversion.convert("2 cups in ml")?.value == "480")
    }
}

struct ColorTextTests {
    private func value(_ text: String) -> String? { ColorText.convert(text)?.value }

    @Test func thePagesExample() {
        #expect(ColorText.convert("#a894ff to rgb")?.text == "#a894ff = rgb(168, 148, 255)")
        #expect(value("#a894ff to rgb") == "rgb(168, 148, 255)")
    }

    @Test func spellingsOfAHexCode() {
        #expect(value("#A894FF in rgb") == "rgb(168, 148, 255)")
        #expect(value("#abc to rgb") == "rgb(170, 187, 204)")
        #expect(value("#a894ff80 to rgb") == "rgba(168, 148, 255, 0.5)")
    }

    @Test func otherWaysRound() {
        #expect(value("rgb(168, 148, 255) to hex") == "#a894ff")
        #expect(value("rgb(168 148 255) to hex") == "#a894ff")
        #expect(value("#a894ff80 to hex") == "#a894ff80")
    }

    @Test func hueSaturationAndLightness() {
        #expect(value("#a894ff to hsl") == "hsl(251, 100%, 79%)")
        #expect(value("#ff0000 to hsl") == "hsl(0, 100%, 50%)")
        #expect(value("#00ff00 to hsl") == "hsl(120, 100%, 50%)")
        #expect(value("#808080 to hsl") == "hsl(0, 0%, 50%)")
        #expect(value("#ffffff to hsl") == "hsl(0, 0%, 100%)")
    }

    @Test(arguments: ["#zzzzzz to rgb", "#a894f to rgb", "#a894ff to cmyk", "a894ff to rgb", "rgb(300, 0, 0) to hex", "#a894ff", "rgb to hex"])
    func whatIsntAColor(text: String) {
        #expect(ColorText.convert(text) == nil)
    }
}

/// Which row each of these lands on, through the real field.
@MainActor
@Suite(.serialized)
struct CommandAnswerRowTests {
    private let viewModel: NotchViewModel

    init() {
        SnapshotRenderer.useScratchDefaults()
        viewModel = NotchViewModel(geometry: NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                                           closedSize: CGSize(width: 186, height: 37), hasHardwareNotch: true))
    }

    private func first(_ text: String) -> String? { CommandEngine.results(for: text, in: viewModel).first?.id }

    @Test func eachAnswerHasItsRow() {
        #expect(first("2026-10-31") == "date")
        #expect(first("days until 25 dec") == "date")
        #expect(first("1.5 gb to mb") == "convert")
        #expect(first("5pm pst in lahore") == "time")
        #expect(first("time in tokyo") == "time")
        #expect(first("#a894ff to rgb") == "color-value")
    }

    @Test func aDayThatDoesntExistIsStillASum() {
        #expect(CommandEngine.results(for: "2026-13-45", in: viewModel).first?.title == "= 1968")
    }

    @Test func sumsAreAsTheyWere() {
        #expect(CommandEngine.results(for: "18% of 240", in: viewModel).first?.title == "= 43.2")
        #expect(CommandEngine.results(for: "4x3", in: viewModel).first?.title == "= 12")
        #expect(CommandEngine.results(for: "10-3", in: viewModel).first?.title == "= 7")
    }

    @Test func aColorRowWearsTheColor() throws {
        let color = try #require(ColorText.convert("#a894ff to rgb")?.color)
        #expect(CommandEngine.results(for: "#a894ff to rgb", in: viewModel).first?.tint == color)
    }

    @Test func returnCopiesTheAnswerToTheScratchClipboard() throws {
        let row = try #require(CommandEngine.results(for: "1.5 gb to mb", in: viewModel).first)
        viewModel.run(row)
        #expect(NSPasteboard.dynotch.string(forType: .string) == "1500")
    }

    @Test func anAnswerIsCountedAsTheOneRowThatOffersThem() {
        for id in ["date", "time", "color-value"] { #expect(CommandEngine.learnedID(of: id) == "sum") }
    }
}
