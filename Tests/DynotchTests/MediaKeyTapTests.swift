import AppKit
import CoreGraphics
import Testing
@testable import Dynotch

/// The volume and brightness keys: what the tap takes, and what waits for the app when it's busy.
/// The tap answers on its own thread and must never wait for the app, or every key and click on the
/// Mac waits with it.
struct MediaKeyTapTests {
    private let everything = KeyRouting(showsHUD: true, canSetVolume: true, canMute: true, canSetBrightness: true)

    @Test func aPlainVolumeKeyIsTaken() {
        let answer = everything.takes(.soundUp, flags: [], pointerOnBuiltIn: true)
        #expect(answer.taken)
        #expect(!answer.fine)
    }

    @Test func shiftOptionAsksForQuarterSteps() {
        let answer = everything.takes(.soundDown, flags: [.maskShift, .maskAlternate], pointerOnBuiltIn: true)
        #expect(answer.taken)
        #expect(answer.fine)
    }

    @Test(arguments: [CGEventFlags.maskCommand, .maskControl, .maskAlternate])
    func keysWithOtherModifiersGoToTheSystem(flags: CGEventFlags) {
        #expect(!everything.takes(.soundUp, flags: flags, pointerOnBuiltIn: true).taken)
    }

    @Test func nothingIsTakenWithTheHUDOff() {
        var routing = everything
        routing.showsHUD = false
        for key in [MediaKey.soundUp, .soundDown, .mute, .brightnessUp, .brightnessDown] {
            #expect(!routing.takes(key, flags: [], pointerOnBuiltIn: true).taken)
        }
    }

    @Test func anOutputWithoutAVolumeLeavesItsKeysToTheSystem() {
        var routing = everything
        routing.canSetVolume = false
        #expect(!routing.takes(.soundUp, flags: [], pointerOnBuiltIn: true).taken)
        // Mute is a control of its own.
        #expect(routing.takes(.mute, flags: [], pointerOnBuiltIn: true).taken)
    }

    @Test func brightnessOnAnotherDisplayGoesToTheSystem() {
        #expect(!everything.takes(.brightnessUp, flags: [], pointerOnBuiltIn: false).taken)
        #expect(everything.takes(.brightnessUp, flags: [], pointerOnBuiltIn: true).taken)
        // Where the pointer is says nothing about the volume.
        #expect(everything.takes(.soundUp, flags: [], pointerOnBuiltIn: false).taken)
    }

    // MARK: The backlog

    @Test func lettingGoDropsWhatHoldingTheKeyStillHadWaiting() {
        var backlog = KeyBacklog()
        backlog.add(KeyPress(key: .soundUp))
        for _ in 0..<10 { backlog.add(KeyPress(key: .soundUp, isRepeat: true)) }
        backlog.release(.soundUp)
        // The press itself still counts: it was meant.
        #expect(backlog.drain() == [KeyPress(key: .soundUp)])
    }

    @Test func lettingGoOfOneKeyLeavesAnother() {
        var backlog = KeyBacklog()
        backlog.add(KeyPress(key: .soundUp, isRepeat: true))
        backlog.add(KeyPress(key: .brightnessDown, isRepeat: true))
        backlog.release(.soundUp)
        #expect(backlog.drain() == [KeyPress(key: .brightnessDown, isRepeat: true)])
    }

    @Test func aHeldKeyNeverQueuesMoreThanAFullSweep() {
        var backlog = KeyBacklog()
        for _ in 0..<500 { backlog.add(KeyPress(key: .soundUp, isRepeat: true)) }
        #expect(backlog.presses.count == KeyBacklog.mostRepeats)
    }

    @Test func theBacklogIsBoundedWhateverArrives() {
        var backlog = KeyBacklog()
        for index in 0..<10_000 {
            backlog.add(KeyPress(key: index.isMultiple(of: 2) ? .soundUp : .mute))
        }
        #expect(backlog.presses.count == KeyBacklog.most)
    }

    @Test func drainingEmptiesIt() {
        var backlog = KeyBacklog()
        backlog.add(KeyPress(key: .mute))
        #expect(backlog.drain().count == 1)
        #expect(backlog.isEmpty)
        #expect(backlog.drain().isEmpty)
    }

    // MARK: Steps

    @Test func aRunOfPressesLandsWhereEachWouldInTurn() {
        let presses = [KeyPress(key: .soundUp), KeyPress(key: .soundUp, isRepeat: true), KeyPress(key: .soundDown)]
        let level = MediaKeyTap.level(from: 0.5, after: presses) { $0 == .soundUp }
        #expect(abs(level - 9.0 / 16) < 0.0001)
    }

    @Test func aRunStopsAtTheEnds() {
        let up = [KeyPress](repeating: KeyPress(key: .soundUp, isRepeat: true), count: 40)
        #expect(MediaKeyTap.level(from: 0.9, after: up) { $0 == .soundUp } == 1)
        let down = [KeyPress](repeating: KeyPress(key: .soundDown, isRepeat: true), count: 40)
        #expect(MediaKeyTap.level(from: 0.1, after: down) { $0 == .soundUp } == 0)
    }

    @Test func quarterStepsAreASixtyFourth() {
        let level = MediaKeyTap.level(from: 0.5, after: [KeyPress(key: .soundUp, fine: true)]) { $0 == .soundUp }
        #expect(abs(level - 33.0 / 64) < 0.0001)
    }

    // MARK: The tap's own side

    /// A key event as the keyboard sends it, made here and handed straight to the tap's handler.
    /// Nothing is posted to the system.
    private func event(_ key: MediaKey, down: Bool, isRepeat: Bool = false, flags: NSEvent.ModifierFlags = []) -> CGEvent {
        let data1 = (key.rawValue << 16) | ((down ? 0x0A : 0x0B) << 8) | (isRepeat ? 1 : 0)
        return NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                  context: nil, subtype: 8, data1: data1, data2: -1)!.cgEvent!
    }

    private let systemDefined = CGEventType(rawValue: 14)!

    /// What the app is handed is whatever collected, once, and asking again gives nothing.
    @Test func theCoreHandsItsBacklogOverOnce() {
        let core = KeyTapCore { _ in }
        core.update(everything)
        #expect(core.takeBacklog().isEmpty)
    }

    /// The whole point: the handler answers by itself. Nothing on the main thread runs between the
    /// key and the answer, so a busy app can't hold the Mac's input up.
    @Test func theHandlerTakesAKeyWithoutTheApp() {
        let core = KeyTapCore { _ in }
        core.update(everything)
        #expect(core.handle(type: systemDefined, event: event(.soundUp, down: true)))
        #expect(core.handle(type: systemDefined, event: event(.soundUp, down: true, isRepeat: true)))
        #expect(core.takeBacklog() == [KeyPress(key: .soundUp), KeyPress(key: .soundUp, isRepeat: true)])
    }

    @Test func theHandlerDropsRepeatsWhenTheKeyComesUp() {
        let core = KeyTapCore { _ in }
        core.update(everything)
        _ = core.handle(type: systemDefined, event: event(.soundDown, down: true))
        for _ in 0..<30 { _ = core.handle(type: systemDefined, event: event(.soundDown, down: true, isRepeat: true)) }
        // The release of a key Dynotch took is taken too.
        #expect(core.handle(type: systemDefined, event: event(.soundDown, down: false)))
        #expect(core.takeBacklog() == [KeyPress(key: .soundDown)])
    }

    /// The system never sees half a key: a release goes with its press, to Dynotch or to the system.
    @Test func aReleaseFollowsItsPress() {
        let core = KeyTapCore { _ in }
        core.update(KeyRouting(showsHUD: true))
        // No volume to set: the press goes to the system, and so does its release.
        #expect(!core.handle(type: systemDefined, event: event(.soundUp, down: true)))
        #expect(!core.handle(type: systemDefined, event: event(.soundUp, down: false)))
        // Taken, and then the output changes before the key comes up: the release is still Dynotch's.
        core.update(everything)
        #expect(core.handle(type: systemDefined, event: event(.soundUp, down: true)))
        core.update(KeyRouting(showsHUD: true))
        #expect(core.handle(type: systemDefined, event: event(.soundUp, down: false)))
        #expect(!core.handle(type: systemDefined, event: event(.soundUp, down: false)))
    }

    @Test func otherKeysAndModifiersPassThrough() {
        let core = KeyTapCore { _ in }
        core.update(everything)
        // Play/pause is key 16: not Dynotch's.
        let play = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                      context: nil, subtype: 8, data1: (16 << 16) | (0x0A << 8), data2: -1)!.cgEvent!
        #expect(!core.handle(type: systemDefined, event: play))
        // A mouse button's system-defined event, which every click sends through the tap.
        let click = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                       context: nil, subtype: 7, data1: 1, data2: 1)!.cgEvent!
        #expect(!core.handle(type: systemDefined, event: click))
        #expect(!core.handle(type: systemDefined, event: event(.soundUp, down: true, flags: .command)))
        #expect(core.takeBacklog().isEmpty)
    }

    /// macOS gives a tap about a second for each event before it turns the tap off, and holds every
    /// other event up meanwhile. The handler has to be far inside that, for clicks most of all,
    /// since every click on the Mac passes through it.
    @Test func theHandlerIsQuick() {
        let core = KeyTapCore { _ in }
        core.update(everything)
        let click = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                       context: nil, subtype: 7, data1: 1, data2: 1)!.cgEvent!
        let key = event(.soundUp, down: true, isRepeat: true)
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<1000 {
            _ = core.handle(type: systemDefined, event: click)
            _ = core.handle(type: systemDefined, event: key)
        }
        let each = Double(DispatchTime.now().uptimeNanoseconds - start) / 2000 / 1e6
        // Half a millisecond each is two thousand times inside the limit, and loose enough for a busy CI Mac.
        #expect(each < 0.5, "\(each) ms an event")
    }

    /// The app is woken once for a burst, not once for each key.
    @Test func aBurstWakesTheAppOnce() async {
        let wakes = Counter()
        let core = KeyTapCore { _ in wakes.add() }
        core.update(everything)
        for _ in 0..<12 { _ = core.handle(type: systemDefined, event: event(.soundUp, down: true, isRepeat: true)) }
        // The wake runs on the main queue; give it a turn.
        await MainActor.run {}
        try? await Task.sleep(for: .milliseconds(50))
        #expect(wakes.value == 1)
        #expect(core.takeBacklog().count == 12)
        // Once the app has taken them, the next key wakes it again.
        _ = core.handle(type: systemDefined, event: event(.soundUp, down: true))
        await MainActor.run {}
        try? await Task.sleep(for: .milliseconds(50))
        #expect(wakes.value == 2)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}

/// One copy of Dynotch at a time: the copy opened last stays.
struct SingleCopyTests {
    @Test func theEarlierCopyGivesWay() {
        let early = SingleCopy.Start(date: Date(timeIntervalSince1970: 100), pid: 900)
        let late = SingleCopy.Start(date: Date(timeIntervalSince1970: 101), pid: 200)
        #expect(early.isOlder(than: late))
        #expect(!late.isOlder(than: early))
    }

    /// Two copies opened in the same instant, as at login, still agree on which one stays.
    @Test func aTieIsSettledTheSameWayFromBothSides() {
        let date = Date(timeIntervalSince1970: 100)
        let one = SingleCopy.Start(date: date, pid: 300), other = SingleCopy.Start(date: date, pid: 301)
        #expect(one.isOlder(than: other) != other.isOlder(than: one))
    }

    @Test func aCopyWithNoStartTimeCountsAsOldest() {
        let unknown = SingleCopy.Start(date: nil, pid: 999)
        let known = SingleCopy.Start(date: Date(timeIntervalSince1970: 1), pid: 1)
        #expect(unknown.isOlder(than: known))
    }
}
