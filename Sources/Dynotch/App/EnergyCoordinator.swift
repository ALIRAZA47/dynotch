import AppKit
import Combine

/// How often a poll runs: on power, on battery, and in Low Power Mode.
struct Cadence: Equatable {
    let name: String
    let every: TimeInterval
    let onBattery: TimeInterval
    let lowPower: TimeInterval
}

/// Every periodic poll in Dynotch, in one place. Anything not listed is driven by events:
/// Core Audio and IOKit listeners, file system sources, distributed notifications.
extension Cadence {
    /// CPU, memory, disk and network, while the Stats tab is on screen.
    static let systemStats = Cadence(name: "Control tab", every: 1.5, onBattery: 3, lowPower: 5)
    /// Focus schedules start and end without touching the files that are watched.
    static let focusSchedules = Cadence(name: "Focus schedules", every: 30, onBattery: 60, lowPower: 120)
    /// `system_profiler` for Bluetooth battery levels, which nothing announces.
    static let bluetoothBatteries = Cadence(name: "Bluetooth batteries", every: 120, onBattery: 300, lowPower: 600)
    /// Often enough to catch rain half an hour before it starts.
    static let weather = Cadence(name: "Weather", every: 10 * 60, onBattery: 15 * 60, lowPower: 20 * 60)
    /// A partial download that grew in the last two minutes: files don't change the folder as they grow.
    static let downloadMoving = Cadence(name: "Download moving", every: 1, onBattery: 2, lowPower: 3)
    /// One that's stopped for a while, which may start again.
    static let downloadStalled = Cadence(name: "Download stalled", every: 10, onBattery: 20, lowPower: 30)
    /// One that hasn't moved for half an hour, like a paused Safari download.
    static let downloadDormant = Cadence(name: "Old partial download", every: 30, onBattery: 60, lowPower: 120)
    /// Events five minutes ahead and as they start: at least once a minute.
    static let eventAlerts = Cadence(name: "Event alerts", every: 30, onBattery: 45, lowPower: 45)
    /// The Screenshot app's save folder can change, and nothing says so.
    static let screenshotFolder = Cadence(name: "Screenshot folder", every: 60, onBattery: 120, lowPower: 300)
    /// The Pomodoro and named timers counting down in the notch.
    static let countdown = Cadence(name: "Timer countdown", every: 0.5, onBattery: 0.5, lowPower: 1)
    /// Accessibility is granted in System Settings, which doesn't tell the app.
    static let accessibilityCheck = Cadence(name: "Accessibility check", every: 2, onBattery: 2, lowPower: 4)
}

/// Keeps Dynotch quiet when nobody's looking. Polls pause while the displays sleep, the screen is
/// locked, the screen saver runs or another user has the Mac, and catch up when someone's back.
/// On battery and in Low Power Mode they run less often. Services schedule their polls here
/// rather than with timers of their own; work due at a set time, like a timer ending, still runs.
@MainActor
final class EnergyCoordinator: ObservableObject {
    static let shared = EnergyCoordinator()

    struct Conditions: Equatable {
        var displaysAsleep = false
        var screenLocked = false
        var screenSaver = false
        /// Another user has the Mac, through fast user switching.
        var sessionInactive = false
        var onBattery = false
        var lowPowerMode = false

        /// Nobody can see the screen.
        var isQuiet: Bool { displaysAsleep || screenLocked || screenSaver || sessionInactive }
    }

    @Published private(set) var conditions = Conditions()

    var isQuiet: Bool { conditions.isQuiet }

    private var polls: [Poll] = []
    private var isStarted = false
    private var lastLook = Date.distantPast
    private var cancellables = Set<AnyCancellable>()

    /// The app uses `shared`; the energy probe makes its own.
    init() {}

    func start() {
        guard !isStarted else { return }
        isStarted = true
        var initial = conditions
        initial.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        Self.readScreen(into: &initial)
        update(initial)

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.displaysAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.displaysAsleep = false }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionInactive = true }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionInactive = false }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.screenLocked = true }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.screenLocked = false }
        observe(distributed, Notification.Name("com.apple.screensaver.didstart")) { $0.screenSaver = true }
        observe(distributed, Notification.Name("com.apple.screensaver.didstop")) { $0.screenSaver = false }
        // Posted on whichever thread changed it.
        NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.change { $0.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled } }
            .store(in: &cancellables)
        let power = PowerMonitor.shared
        Publishers.CombineLatest(power.$hasBattery, power.$isPluggedIn)
            .map { hasBattery, pluggedIn in hasBattery && !pluggedIn }
            .removeDuplicates()
            .sink { [weak self] onBattery in self?.change { $0.onBattery = onBattery } }
            .store(in: &cancellables)
    }

    /// Runs `work` every so often, as `cadence` says for the power the Mac is on, while someone's
    /// looking. With a `deadline`, it also runs at that time while nobody is.
    func schedule(_ cadence: Cadence, deadline: (@MainActor () -> Date?)? = nil,
                  _ work: @escaping @MainActor () -> Void) -> Poll {
        let poll = Poll(cadence: cadence, deadline: deadline, work: work, coordinator: self)
        polls.append(poll)
        arm(poll)
        return poll
    }

    /// How long between polls right now, with someone looking.
    func interval(for cadence: Cadence) -> TimeInterval {
        conditions.lowPowerMode ? cadence.lowPower : conditions.onBattery ? cadence.onBattery : cadence.every
    }

    /// The pointer moved while nobody was supposed to be looking. In case the notification that
    /// the screen woke, unlocked or left the screen saver went missing, look at the screen itself,
    /// at most once a second.
    func sawInput() {
        guard isQuiet, Date.now.timeIntervalSince(lastLook) > 1 else { return }
        lastLook = .now
        var next = conditions
        Self.readScreen(into: &next)
        if next.screenSaver {
            next.screenSaver = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.ScreenSaver.Engine" }
        }
        update(next)
    }

    /// Whether the main display sleeps, the screen is locked, and this user has the Mac, from the
    /// window server.
    private static func readScreen(into conditions: inout Conditions) {
        conditions.displaysAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return }
        conditions.screenLocked = session["CGSSessionScreenIsLocked"] as? Bool ?? false
        conditions.sessionInactive = !(session["kCGSSessionOnConsoleKey"] as? Bool ?? true)
    }

    /// Sets the conditions. The probe drives these by hand.
    func update(_ next: Conditions) {
        guard next != conditions else { return }
        let wasQuiet = conditions.isQuiet
        conditions = next
        // Polls that came due while nobody was looking run now, a moment apart.
        let resuming = wasQuiet && !next.isQuiet
        for (index, poll) in polls.enumerated() {
            arm(poll, catchUpDelay: resuming ? 0.3 * Double(index) : 0)
        }
    }

    // MARK: Polls

    fileprivate func cancel(_ poll: Poll) {
        poll.timer?.invalidate()
        poll.timer = nil
        polls.removeAll { $0 === poll }
    }

    fileprivate func change(_ poll: Poll, to cadence: Cadence) {
        guard poll.cadence != cadence, polls.contains(where: { $0 === poll }) else { return }
        poll.cadence = cadence
        arm(poll)
    }

    /// Sets the poll's timer for its next run: an interval after the last one, at once if that's
    /// past, or only at its deadline while nobody's looking.
    private func arm(_ poll: Poll, catchUpDelay: TimeInterval = 0) {
        poll.timer?.invalidate()
        poll.timer = nil
        let now = Date.now
        let date: Date, tolerance: TimeInterval
        if conditions.isQuiet {
            // Once per deadline: one the poll has run since is spent until the work moves it.
            guard let deadline = poll.deadline?(), deadline > poll.lastRun else { return }
            date = max(deadline, now)
            tolerance = min(0.25, poll.cadence.every)
        } else {
            let interval = interval(for: poll.cadence)
            let due = poll.lastRun.addingTimeInterval(interval)
            date = due > now ? due : now.addingTimeInterval(catchUpDelay)
            // Leeway lets macOS run timers together with other wakeups.
            tolerance = interval * 0.1
        }
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self, weak poll] _ in
            MainActor.assumeIsolated {
                guard let self, let poll else { return }
                self.run(poll)
            }
        }
        timer.tolerance = tolerance
        RunLoop.main.add(timer, forMode: .common)
        poll.timer = timer
    }

    private func run(_ poll: Poll) {
        guard polls.contains(where: { $0 === poll }) else { return }
        poll.timer = nil
        poll.lastRun = .now
        poll.work()
        // The work may have cancelled or changed it.
        if poll.timer == nil, polls.contains(where: { $0 === poll }) { arm(poll) }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ apply: @escaping (inout Conditions) -> Void) {
        center.publisher(for: name)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.change(apply) }
            .store(in: &cancellables)
    }

    private func change(_ apply: (inout Conditions) -> Void) {
        var next = conditions
        apply(&next)
        update(next)
    }
}

/// A poll the coordinator paces. Cancel it to stop it.
@MainActor
final class Poll {
    fileprivate(set) var cadence: Cadence
    fileprivate let deadline: (@MainActor () -> Date?)?
    fileprivate let work: @MainActor () -> Void
    fileprivate var timer: Timer?
    fileprivate var lastRun = Date.now
    private weak var coordinator: EnergyCoordinator?

    fileprivate init(cadence: Cadence, deadline: (@MainActor () -> Date?)?, work: @escaping @MainActor () -> Void,
                     coordinator: EnergyCoordinator) {
        self.cadence = cadence
        self.deadline = deadline
        self.work = work
        self.coordinator = coordinator
    }

    func cancel() {
        coordinator?.cancel(self)
    }

    /// Runs at another pace from now on, counting from the last run.
    func change(to cadence: Cadence) {
        coordinator?.change(self, to: cadence)
    }
}
