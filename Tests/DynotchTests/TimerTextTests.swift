import Testing
@testable import Dynotch

struct TimerTextTests {
    @Test(arguments: ["99999999999999999999:30", "9223372036854775808:30", "99999999999999999999:30:00"])
    func aClockTooBigForAnIntIsNoTimer(text: String) {
        #expect(TimerText.parse(text) == nil)
    }

    @Test func clocksStillRead() {
        #expect(TimerText.parse("4:30 noodles")?.duration == 270)
        #expect(TimerText.parse("4:30 noodles")?.name == "Noodles")
        #expect(TimerText.parse("1:05:00")?.duration == 3900)
    }
}
