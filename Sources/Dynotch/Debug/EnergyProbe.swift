import AppKit
import SwiftUI

/// `Dynotch --energy-probe` counts how often Dynotch's polls would wake the Mac in an hour, the way
/// they ran before EnergyCoordinator (plain repeating timers) and with it, in a few situations and
/// conditions. Time runs 240 times faster, so a simulated hour takes 15 seconds. It also measures
/// the closed notch with music playing, on screen and with its views taken off the panel, as
/// NotchWindowController does while nobody's looking. It starts none of the real services, shows
/// nothing on screen and changes no settings.
@MainActor
enum EnergyProbe {
    private static let speed: Double = 240
    private static let hour: TimeInterval = 3600

    /// One poll in a situation: its cadence, and for the Pomodoro, when its phase ends.
    private struct Entry {
        let cadence: Cadence
        /// The interval it ran at before, when that isn't the cadence's own.
        var before: TimeInterval?
        /// Seconds into the hour when it's done, like a 25-minute focus session.
        var endsAt: TimeInterval?
    }

    private struct Situation {
        let name: String
        let entries: [Entry]
    }

    private enum Condition: String, CaseIterable {
        case power = "On power", battery = "On battery", lowPower = "Low Power Mode"
        case asleep = "Displays asleep", locked = "Screen locked"
    }

    private struct Result {
        var fires: [Int]
        var runLoopWakeups: Int
        var kernelWakeups: UInt64
    }

    /// Runs per poll, counted from timer callbacks.
    @MainActor
    private final class Tally {
        var fires: [Int]

        init(_ count: Int) {
            fires = Array(repeating: 0, count: count)
        }
    }

    static func run(notchOnly: Bool = false) {
        // Agent apps with no window on screen get App Nap, which would bunch the timers up.
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Energy probe")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        installWakeupCounter()
        if notchOnly {
            measureClosedNotch()
            return
        }

        let idle = [Entry(cadence: .focusSchedules), Entry(cadence: .eventAlerts), Entry(cadence: .weather),
                    Entry(cadence: .bluetoothBatteries), Entry(cadence: .screenshotFolder)]
        let situations = [
            Situation(name: "Idle: Focus, events, weather, Bluetooth, screenshot folder", entries: idle),
            Situation(name: "Idle, with an old partial download in ~/Downloads",
                      entries: idle + [Entry(cadence: .downloadDormant, before: Cadence.downloadStalled.every)]),
            Situation(name: "Busy: Control tab open, a download moving, a 25-minute Pomodoro",
                      entries: idle + [Entry(cadence: .systemStats), Entry(cadence: .downloadMoving),
                                       Entry(cadence: .countdown, endsAt: 25 * 60)]),
        ]

        print("Energy probe: each column is one simulated hour, with time running \(Int(speed))× faster.")
        print("\"Before\" runs plain repeating timers, as the services had; the others run EnergyCoordinator.\n")
        for situation in situations {
            let before = measureBefore(situation)
            var after: [Condition: Result] = [:]
            for condition in Condition.allCases { after[condition] = measureAfter(situation, condition) }
            printTable(situation, before: before, after: after)
        }
        measureRealTime()
        measureClosedNotch()
    }

    /// The fast polls at their real pace for a minute, on power: sped up, timers' leeway is too
    /// short for macOS to run them together, so this shows what that leeway buys.
    private static func measureRealTime() {
        let entries = [Entry(cadence: .systemStats), Entry(cadence: .downloadMoving), Entry(cadence: .countdown)]
        let situation = Situation(name: "Real time, one minute on power: Control tab, a download and a timer",
                                  entries: entries)
        let speed = 1.0
        let minute: TimeInterval = 60
        func run(_ schedule: (Tally) -> () -> Void) -> Result {
            let tally = Tally(entries.count)
            let stop = schedule(tally)
            let loopStart = wakeups
            let kernelStart = kernelWakeups()
            RunLoop.main.run(until: .now + minute / speed)
            stop()
            return Result(fires: tally.fires, runLoopWakeups: wakeups - loopStart, kernelWakeups: kernelWakeups() - kernelStart)
        }
        let before = run { tally in
            let timers = entries.enumerated().map { index, entry in
                let timer = Timer(timeInterval: entry.cadence.every, repeats: true) { _ in
                    MainActor.assumeIsolated { tally.fires[index] += 1 }
                }
                RunLoop.main.add(timer, forMode: .common)
                return timer
            }
            return { timers.forEach { $0.invalidate() } }
        }
        let after = run { tally in
            let coordinator = EnergyCoordinator()
            let polls = entries.enumerated().map { index, entry in
                coordinator.schedule(entry.cadence) { tally.fires[index] += 1 }
            }
            return { withExtendedLifetime(coordinator) { polls.forEach { $0.cancel() } } }
        }
        print(situation.name)
        print(pad("Runs in a minute", 30) + pad("Before", 16, right: true) + pad("After", 16, right: true))
        for (index, entry) in entries.enumerated() {
            print(pad("  " + entry.cadence.name, 30) + pad("\(before.fires[index])", 16, right: true)
                + pad("\(after.fires[index])", 16, right: true))
        }
        print(pad("Main-thread wakeups", 30) + pad("\(before.runLoopWakeups)", 16, right: true)
            + pad("\(after.runLoopWakeups)", 16, right: true))
        print(pad("Kernel wakeups (interrupt)", 30) + pad("\(before.kernelWakeups)", 16, right: true)
            + pad("\(after.kernelWakeups)", 16, right: true))
        print("")
    }

    // MARK: Runs

    private static func measureBefore(_ situation: Situation) -> Result {
        let tally = Tally(situation.entries.count)
        let start = Date.now
        var timers: [Timer] = []
        for (index, entry) in situation.entries.enumerated() {
            let ends = entry.endsAt.map { start.addingTimeInterval($0 / speed) }
            let timer = Timer(timeInterval: (entry.before ?? entry.cadence.every) / speed, repeats: true) { timer in
                MainActor.assumeIsolated { tally.fires[index] += 1 }
                if let ends, Date.now >= ends { timer.invalidate() }
            }
            RunLoop.main.add(timer, forMode: .common)
            timers.append(timer)
        }
        let result = measure { tally.fires }
        timers.forEach { $0.invalidate() }
        return result
    }

    private static func measureAfter(_ situation: Situation, _ condition: Condition) -> Result {
        let coordinator = EnergyCoordinator()
        coordinator.start()
        var conditions = EnergyCoordinator.Conditions()
        conditions.onBattery = condition == .battery
        conditions.lowPowerMode = condition == .lowPower
        conditions.screenLocked = condition == .locked
        coordinator.update(conditions)
        if condition == .asleep {
            // Through the same notification macOS posts, to the coordinator's own observer.
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
            RunLoop.main.run(until: .now + 0.05)
        }
        let tally = Tally(situation.entries.count)
        let start = Date.now
        var polls: [Poll] = []
        for (index, entry) in situation.entries.enumerated() {
            let ends = entry.endsAt.map { start.addingTimeInterval($0 / speed) }
            let cadence = Cadence(name: entry.cadence.name, every: entry.cadence.every / speed,
                                  onBattery: entry.cadence.onBattery / speed, lowPower: entry.cadence.lowPower / speed)
            let deadline: (@MainActor () -> Date?)? = ends.map { date in { date } }
            var poll: Poll?
            poll = coordinator.schedule(cadence, deadline: deadline) {
                tally.fires[index] += 1
                if let ends, Date.now >= ends { poll?.cancel() }
            }
            polls.append(poll!)
        }
        let result = measure { tally.fires }
        polls.forEach { $0.cancel() }
        return result
    }

    /// Runs the run loop for a simulated hour, counting its wakeups and the kernel's.
    private static func measure(_ fires: () -> [Int]) -> Result {
        let loopStart = wakeups
        let kernelStart = kernelWakeups()
        RunLoop.main.run(until: .now + hour / speed)
        return Result(fires: fires(), runLoopWakeups: wakeups - loopStart, kernelWakeups: kernelWakeups() - kernelStart)
    }

    // MARK: The closed notch

    /// The real closed notch with music playing, in a panel off screen: how often the main thread
    /// wakes with its views on the panel, and with them taken off.
    private static func measureClosedNotch() {
        NowPlayingService.shared.loadSample(NowPlayingService.Track(title: "Midnight City", artist: "M83",
                                                                    album: "Hurry Up, We're Dreaming", duration: 243),
                                            playing: true, elapsed: 81)
        let geometry = NotchGeometry(screenFrame: CGRect(x: -30_000, y: -30_000, width: 1728, height: 1117),
                                     closedSize: CGSize(width: 185, height: 32), hasHardwareNotch: true)
        let viewModel = NotchViewModel(geometry: geometry)
        viewModel.stage(phase: .closed, activity: .music)
        let panel = ProbePanel(contentRect: CGRect(x: -30_000, y: -30_000, width: 760, height: 250),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let host = NotchHostingView(rootView: NotchRootView(viewModel: viewModel))
        panel.contentView = host
        panel.orderFrontRegardless()
        RunLoop.main.run(until: .now + 1)

        let seconds: TimeInterval = 6
        func sample() -> Double {
            let start = wakeups
            RunLoop.main.run(until: .now + seconds)
            return Double(wakeups - start) / seconds
        }
        let attached = sample()
        panel.contentView = NSView()
        panel.orderOut(nil)
        let detached = sample()
        panel.contentView = host
        panel.close()

        print("Closed notch with music playing (the real NotchRootView, \(Int(seconds)) s each)")
        print(String(format: "  views on the panel:                    %6.1f main-thread wakeups a second, %7.0f an hour",
                     attached, attached * hour))
        print(String(format: "  views off the panel (nobody's looking): %6.1f main-thread wakeups a second, %7.0f an hour",
                     detached, detached * hour))
    }

    // MARK: Output

    private static func printTable(_ situation: Situation, before: Result, after: [Condition: Result]) {
        let columns = ["Before"] + Condition.allCases.map(\.rawValue)
        let results = [before] + Condition.allCases.map { after[$0]! }
        print(situation.name)
        print(pad("Polls run in an hour", 30) + columns.map { pad($0, 16, right: true) }.joined())
        for (index, entry) in situation.entries.enumerated() {
            print(pad("  " + entry.cadence.name, 30) + results.map { pad("\($0.fires[index])", 16, right: true) }.joined())
        }
        print(pad("  Total", 30) + results.map { pad("\($0.fires.reduce(0, +))", 16, right: true) }.joined())
        print(pad("Main-thread wakeups", 30) + results.map { pad("\($0.runLoopWakeups)", 16, right: true) }.joined())
        print(pad("Kernel wakeups (interrupt)", 30) + results.map { pad("\($0.kernelWakeups)", 16, right: true) }.joined())
        print("")
    }

    private static func pad(_ text: String, _ width: Int, right: Bool = false) -> String {
        let room = max(0, width - text.count)
        return right ? String(repeating: " ", count: room) + text : text + String(repeating: " ", count: room)
    }

    // MARK: Counting wakeups

    private static var wakeups = 0

    /// Counts each time the main run loop wakes from sleep.
    private static func installWakeupCounter() {
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, 0) { _, _ in
            MainActor.assumeIsolated { EnergyProbe.wakeups += 1 }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// The kernel's count of this process's wakeups by interrupts, timers among them.
    private static func kernelWakeups() -> UInt64 {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? info.ri_interrupt_wkups : 0
    }
}

/// A panel AppKit leaves where it's put, off screen.
private final class ProbePanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
