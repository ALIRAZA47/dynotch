import Combine
import CoreAudio
import Foundation
import Testing
@testable import Dynotch

// The work Dynotch makes other parts of the Mac do: system_profiler for Bluetooth batteries, and
// Core Audio's list of audio clients. Nothing here runs system_profiler, reaches a Bluetooth
// device or touches Core Audio: each part that would goes through a stand-in.

// MARK: Shell

@Suite(.serialized)
struct ShellTimeoutTests {
    @Test func aCommandThatFinishesGivesItsOutput() async {
        let result = await Shell.run("/bin/echo", ["hello"])
        #expect(result.status == 0)
        #expect(result.output == "hello\n")
    }

    @Test func aCommandThatCantStartFails() async {
        let result = await Shell.run("/nonexistent/dynotch-test-command", [])
        #expect(result.status == Shell.failed)
        #expect(result.output.isEmpty)
    }

    @Test func aCommandThatRunsTooLongIsStoppedAndFails() async {
        let started = Date.now
        let result = await Shell.run("/bin/sleep", ["30"], timeout: 0.3)
        let took = Date.now.timeIntervalSince(started)
        #expect(result.status == Shell.failed)
        #expect(result.output.isEmpty)
        // SIGTERM is enough for sleep, so the grace period isn't used.
        #expect(took < Shell.killGrace)
    }

    @Test func aCommandThatIgnoresSIGTERMIsKilled() async {
        let started = Date.now
        // An ignored signal stays ignored through exec, so this sleep shrugs off SIGTERM.
        let result = await Shell.run("/bin/sh", ["-c", "trap '' TERM; exec /bin/sleep 30"], timeout: 0.3)
        let took = Date.now.timeIntervalSince(started)
        #expect(result.status == Shell.failed)
        #expect(took >= Shell.killGrace)
        #expect(took < Shell.killGrace + 5)
    }

    @Test func noTimeoutWaitsForTheCommand() async {
        let result = await Shell.run("/bin/sh", ["-c", "sleep 0.5; echo done"], timeout: nil)
        #expect(result.status == 0)
        #expect(result.output == "done\n")
    }
}

// MARK: Bluetooth batteries

/// The Mac as the battery monitor sees it: readings counted, the clock and the setting by hand.
@MainActor
private final class FakeBluetooth {
    var reads = 0
    var now = Date(timeIntervalSince1970: 1_000_000)
    var alerts = false
    var profile: String? = #"{"SPBluetoothDataType":[]}"#
    var disconnectAnswer = BluetoothMac.Disconnect.closed
    var disconnectedOnMain: Bool?
    /// While set, a reading waits here until `release()`.
    var holdsReads = false
    private var held: CheckedContinuation<Void, Never>?
    let alertsChanged = PassthroughSubject<Void, Never>()

    var isHoldingARead: Bool { held != nil }

    func read() async -> String? {
        reads += 1
        if holdsReads { await withCheckedContinuation { held = $0 } }
        return profile
    }

    func release() {
        let waiting = held
        held = nil
        waiting?.resume()
    }

    var mac: BluetoothMac {
        BluetoothMac(isAuthorized: { true },
                     readProfile: { await self.read() },
                     watchConnections: { _ in },
                     disconnect: { _ in
                         let onMain = Thread.isMainThread
                         return await MainActor.run {
                             self.disconnectedOnMain = onMain
                             return self.disconnectAnswer
                         }
                     },
                     lowBatteryAlerts: { self.alerts },
                     alertsChanged: alertsChanged.eraseToAnyPublisher(),
                     now: { self.now })
    }
}

@MainActor
@Suite(.serialized)
struct BluetoothBatteryPollTests {
    private let fake = FakeBluetooth()
    private let energy = EnergyCoordinator()

    private func monitor() -> DeviceBatteryMonitor {
        let monitor = DeviceBatteryMonitor(mac: fake.mac, energy: energy)
        monitor.settleDelay = .milliseconds(40)
        return monitor
    }

    /// Lets queued tasks on the main actor run, until `done` or a couple of seconds pass.
    private func wait(until done: () -> Bool) async {
        let limit = Date.now.addingTimeInterval(2)
        while !done(), .now < limit {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func theCadenceFollowsWhatNeedsTheLevels() {
        #expect(DeviceBatteryMonitor.cadence(viewers: 0, lowBatteryAlerts: false) == nil)
        #expect(DeviceBatteryMonitor.cadence(viewers: 0, lowBatteryAlerts: true) == .bluetoothBatteryAlerts)
        #expect(DeviceBatteryMonitor.cadence(viewers: 1, lowBatteryAlerts: false) == .bluetoothBatteries)
        #expect(DeviceBatteryMonitor.cadence(viewers: 2, lowBatteryAlerts: true) == .bluetoothBatteries)
        // Alerts alone: no more often than every ten minutes.
        #expect(Cadence.bluetoothBatteryAlerts.every >= 600)
        #expect(Cadence.bluetoothBatteryAlerts.onBattery >= 600)
        #expect(Cadence.bluetoothBatteryAlerts.lowPower >= 600)
    }

    @Test func nothingIsPolledWhenNothingNeedsTheLevels() async {
        let monitor = monitor()
        await monitor.beginMonitoring()?.value
        #expect(fake.reads == 1)
        #expect(monitor.pollCadence == nil)
        #expect(energy.scheduled.isEmpty)
    }

    @Test func viewersAndAlertsSetThePace() async {
        fake.alerts = true
        let monitor = monitor()
        await monitor.beginMonitoring()?.value
        #expect(monitor.pollCadence == .bluetoothBatteryAlerts)

        await monitor.addViewer()?.value
        #expect(monitor.pollCadence == .bluetoothBatteries)
        monitor.addViewer()
        monitor.removeViewer()
        #expect(monitor.pollCadence == .bluetoothBatteries)
        monitor.removeViewer()
        #expect(monitor.pollCadence == .bluetoothBatteryAlerts)
        // One too many doesn't go below none.
        monitor.removeViewer()
        #expect(monitor.pollCadence == .bluetoothBatteryAlerts)

        fake.alerts = false
        fake.alertsChanged.send()
        #expect(monitor.pollCadence == nil)
        #expect(energy.scheduled.isEmpty)
        fake.alerts = true
        fake.alertsChanged.send()
        #expect(energy.scheduled == [.bluetoothBatteryAlerts])
    }

    @Test func aViewerAppearingReadsOnlyOldLevels() async {
        let monitor = monitor()
        await monitor.beginMonitoring()?.value
        #expect(fake.reads == 1)

        // Read a moment ago: fresh enough.
        fake.now += 30
        await monitor.addViewer()?.value
        #expect(fake.reads == 1)
        monitor.removeViewer()

        fake.now += DeviceBatteryMonitor.freshEnough
        await monitor.addViewer()?.value
        #expect(fake.reads == 2)
        // A second view on screen at the same time reads nothing.
        fake.now += DeviceBatteryMonitor.freshEnough * 2
        #expect(monitor.addViewer() == nil)
        #expect(fake.reads == 2)
    }

    @Test func aViewerBeforeMonitoringStartsReadsNothing() async {
        let monitor = monitor()
        #expect(monitor.addViewer() == nil)
        #expect(fake.reads == 0)
        #expect(monitor.pollCadence == nil)
    }

    @Test func aBurstOfConnectsAndDisconnectsReadsOnce() async {
        let monitor = monitor()
        // Long enough that a slow machine can't let it run out in the middle of the burst
        // (CI once took over 40 ms for a 5 ms sleep and read twice).
        monitor.settleDelay = .milliseconds(400)
        var last: Task<Void, Never>?
        for _ in 0..<6 {
            last = monitor.deviceCameOrWent()
            // Let the task just started begin its wait before the next event replaces it.
            await Task.yield()
        }
        await last?.value
        #expect(fake.reads == 1)
        // The ones it replaced never read.
        try? await Task.sleep(for: .milliseconds(120))
        #expect(fake.reads == 1)
    }

    @Test func eventsFarApartReadEach() async {
        let monitor = monitor()
        await monitor.deviceCameOrWent().value
        await monitor.deviceCameOrWent().value
        #expect(fake.reads == 2)
    }

    @Test func aForcedReadDuringAnotherComesAfterItOnce() async {
        let monitor = monitor()
        fake.holdsReads = true
        let first = Task { await monitor.refresh(force: true) }
        await wait { fake.isHoldingARead }
        #expect(fake.reads == 1)
        // Two forced and one ordinary while it runs: one more reading after it.
        await monitor.refresh(force: true)
        await monitor.refresh(force: true)
        await monitor.refresh()
        #expect(fake.reads == 1)
        fake.release()
        await wait { fake.isHoldingARead }
        #expect(fake.reads == 2)
        fake.holdsReads = false
        fake.release()
        await first.value
        #expect(fake.reads == 2)
    }

    @Test func aFailedReadLeavesTheNextFree() async {
        fake.profile = nil
        let monitor = monitor()
        await monitor.refresh(force: true)
        await monitor.refresh(force: true)
        #expect(fake.reads == 2)
    }

    @Test func aDisconnectThatFailsSaysSo() async {
        fake.disconnectAnswer = .notConnected
        let monitor = monitor()
        let mouse = DeviceBatteryMonitor.Device(id: "AA:BB:CC:DD:EE:FF", name: "Mouse", kind: .mouse)
        let task = monitor.disconnect(mouse)
        #expect(monitor.connections[mouse.id] == .disconnecting)
        // A second click while it's waiting does nothing.
        #expect(monitor.disconnect(mouse) == nil)
        await task?.value
        #expect(monitor.connections[mouse.id] == .failed("Couldn't disconnect"))
        #expect(fake.disconnectedOnMain == false)
        #expect(fake.reads == 0)
    }

    @Test func aDisconnectThatWorksReadsTheLevelsOnce() async {
        let monitor = monitor()
        let mouse = DeviceBatteryMonitor.Device(id: "AA:BB:CC:DD:EE:FF", name: "Mouse", kind: .mouse)
        let task = monitor.disconnect(mouse)
        await wait { fake.reads == 1 }
        #expect(fake.reads == 1)
        #expect(fake.disconnectedOnMain == false)
        // The device isn't in the (empty) reading, so the disconnect is done.
        #expect(monitor.connections[mouse.id] == nil)
        task?.cancel()
    }
}

// MARK: Core Audio clients

/// Stands in for Core Audio's list of clients. Everything is behind a lock, since the watcher calls
/// it from its own queue.
private final class FakeAudioSystem: @unchecked Sendable {
    private let lock = NSLock()
    private var _list: [AudioObjectID] = []
    private var _recording: Set<AudioObjectID> = []
    private var _pids: [AudioObjectID: pid_t] = [:]
    private var _listReads = 0
    private var _pidReads: [AudioObjectID] = []
    private var _recordReads: [AudioObjectID] = []
    private var _watched: [AudioObjectID] = []
    private var _unwatched: [AudioObjectID] = []
    private var _listChanged: (@Sendable () -> Void)?
    private var _clientChanged: [AudioObjectID: @Sendable () -> Void] = [:]
    private var _queue: DispatchQueue?

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func set(list: [AudioObjectID], recording: Set<AudioObjectID> = [], pids: [AudioObjectID: pid_t] = [:]) {
        locked {
            _list = list
            _recording = recording
            _pids.merge(pids) { $1 }
        }
    }

    func setRecording(_ recording: Set<AudioObjectID>) { locked { _recording = recording } }

    var listReads: Int { locked { _listReads } }
    var pidReads: [AudioObjectID] { locked { _pidReads } }
    var recordReads: [AudioObjectID] { locked { _recordReads } }
    var watched: [AudioObjectID] { locked { _watched } }
    var unwatched: [AudioObjectID] { locked { _unwatched } }

    /// What Core Audio does when the list changes: call the listener on the watcher's queue.
    func announceListChange() {
        let (queue, changed) = locked { (_queue, _listChanged) }
        if let queue, let changed { queue.async { changed() } }
    }

    func changeCallback(of process: AudioObjectID) -> (@Sendable () -> Void)? {
        locked { _clientChanged[process] }
    }

    func announceChange(of process: AudioObjectID) {
        let (queue, changed) = locked { (_queue, _clientChanged[process]) }
        if let queue, let changed { queue.async { changed() } }
    }

    var system: AudioClientWatcher.System {
        AudioClientWatcher.System(
            processes: { self.locked { self._listReads += 1; return self._list } },
            pid: { process in self.locked { self._pidReads.append(process); return self._pids[process] ?? pid_t(process) + 10_000 } },
            isRecording: { process in self.locked { self._recordReads.append(process); return self._recording.contains(process) } },
            watchList: { queue, changed in self.locked { self._queue = queue; self._listChanged = changed } },
            watch: { process, queue, changed in
                self.locked {
                    self._queue = queue
                    self._watched.append(process)
                    self._clientChanged[process] = changed
                }
                return NSNumber(value: process)
            },
            unwatch: { process, token, _ in
                self.locked {
                    precondition((token as? NSNumber)?.uint32Value == process)
                    self._unwatched.append(process)
                    self._clientChanged[process] = nil
                }
            })
    }
}

private final class Answers: @unchecked Sendable {
    private let lock = NSLock()
    private var _all: [(inUse: Bool, answer: Int)] = []

    func add(_ inUse: Bool, _ answer: Int) {
        lock.lock()
        _all.append((inUse, answer))
        lock.unlock()
    }

    var all: [(inUse: Bool, answer: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return _all
    }
}

@Suite(.serialized)
struct AudioClientWatcherTests {
    private static let ownPID: pid_t = 4242
    private static let debounce: TimeInterval = 0.05

    private let audio = FakeAudioSystem()
    private let answers = Answers()

    private func watcher() -> AudioClientWatcher {
        let answers = answers
        return AudioClientWatcher(system: audio.system, ownPID: Self.ownPID, debounce: Self.debounce) { answers.add($0, $1) }
    }

    /// Everything the watcher was asked to do, debounced work included, is done.
    private func settle(_ watcher: AudioClientWatcher) async throws -> Set<AudioObjectID> {
        try await Task.sleep(for: .seconds(Self.debounce * 3))
        return try await offThePool { watcher.watchedClients() }
    }

    @Test func theDiffNamesOnlyWhatCameAndWent() {
        let (added, removed) = AudioClientWatcher.diff(known: [1, 2, 3], ignored: [9], current: [2, 3, 4, 9, 4, 5])
        #expect(added == [4, 5])
        #expect(removed == [1])
        let same = AudioClientWatcher.diff(known: [1, 2], ignored: [], current: [2, 1])
        #expect(same.added.isEmpty && same.removed.isEmpty)
    }

    @Test func startingWatchesEveryClientButDynotch() async throws {
        audio.set(list: [10, 11, 12], pids: [12: Self.ownPID])
        let watcher = watcher()
        watcher.start()
        #expect(try await settle(watcher) == [10, 11])
        #expect(Set(audio.watched) == [10, 11])
        #expect(audio.listReads == 1)
    }

    @Test func aListChangeTouchesOnlyClientsThatCameOrWent() async throws {
        audio.set(list: [10, 11, 12], pids: [12: Self.ownPID])
        let watcher = watcher()
        watcher.start()
        _ = try await settle(watcher)

        audio.set(list: [11, 12, 13])
        audio.announceListChange()
        #expect(try await settle(watcher) == [11, 13])
        #expect(audio.unwatched == [10])
        // 11 was watched and read once, at the start; 13 once, now. Dynotch's PID only the first time.
        #expect(audio.watched.sorted() == [10, 11, 13])
        #expect(audio.recordReads.filter { $0 == 11 }.count == 1)
        #expect(audio.recordReads.filter { $0 == 13 }.count == 1)
        #expect(audio.pidReads.filter { $0 == 12 }.count == 1)
        #expect(audio.pidReads.filter { $0 == 11 }.count == 1)
    }

    @Test func aBurstOfListChangesIsTakenOnce() async throws {
        audio.set(list: [10])
        let watcher = watcher()
        watcher.start()
        _ = try await settle(watcher)
        #expect(audio.listReads == 1)

        for _ in 0..<10 { audio.announceListChange() }
        audio.set(list: [10, 11])
        _ = try await settle(watcher)
        #expect(audio.listReads == 2)
    }

    @Test func aClientChangingRereadsOnlyItself() async throws {
        audio.set(list: [10, 11, 12])
        let watcher = watcher()
        watcher.start()
        _ = try await settle(watcher)
        let before = audio.recordReads

        audio.setRecording([11])
        audio.announceChange(of: 11)
        _ = try await settle(watcher)
        #expect(Array(audio.recordReads.dropFirst(before.count)) == [11])
        #expect(audio.listReads == 1)
        #expect(answers.all.last?.inUse == true)
    }

    @Test func itAnswersOnlyWhenRecordingStartsOrStops() async throws {
        audio.set(list: [10, 11])
        let watcher = watcher()
        watcher.start()
        _ = try await settle(watcher)
        #expect(answers.all.map(\.inUse) == [false])

        audio.setRecording([10])
        audio.announceChange(of: 10)
        // Still in use: nothing new to say.
        audio.announceChange(of: 11)
        _ = try await settle(watcher)
        #expect(answers.all.map(\.inUse) == [false, true])

        // The one recording goes away: no longer in use.
        audio.set(list: [11], recording: [10])
        audio.announceListChange()
        _ = try await settle(watcher)
        #expect(answers.all.map(\.inUse) == [false, true, false])
        let numbers = answers.all.map(\.answer)
        #expect(numbers == numbers.sorted() && Set(numbers).count == numbers.count)
    }

    @Test func dynotchRecordingNeverCounts() async throws {
        audio.set(list: [10, 12], recording: [12], pids: [12: Self.ownPID])
        let watcher = watcher()
        watcher.start()
        _ = try await settle(watcher)
        #expect(answers.all.map(\.inUse) == [false])
        #expect(!audio.recordReads.contains(12))
    }

    @Test func aChangeFromAClientThatWentIsIgnored() async throws {
        audio.set(list: [10, 11])
        let watcher = watcher()
        watcher.start()
        _ = try await settle(watcher)
        let reads = audio.recordReads.count
        let late = try #require(audio.changeCallback(of: 10))
        audio.set(list: [11])
        audio.announceListChange()
        _ = try await settle(watcher)
        // Delivered after it went, as a listener already on its way can be.
        watcher.queue.async { late() }
        _ = try await settle(watcher)
        #expect(audio.recordReads.count == reads)
    }
}

// MARK: The equalizer's clients

struct AudioClientDirectoryTests {
    @Test func bundleIDsAreReadOncePerClient() {
        var directory = AudioClientDirectory()
        let ids: [AudioObjectID: String] = [1: "com.spotify.client", 2: "com.spotify.client.helper", 3: "com.apple.Music",
                                            4: "com.spotify.clientx", 5: "app.dynotch.Dynotch"]
        let read: (AudioObjectID) -> String? = { ids[$0] }
        #expect(directory.update(list: [1, 2, 3, 4], bundleID: read) == 4)
        #expect(directory.processes(for: "com.spotify.client") == [1, 2])
        // A Now Playing change, or a tap of Dynotch's own appearing: nothing more read for the old ones.
        #expect(directory.update(list: [1, 2, 3, 4], bundleID: read) == 0)
        #expect(directory.update(list: [1, 2, 3, 4, 5], bundleID: read) == 1)
        #expect(directory.processes(for: "com.spotify.client") == [1, 2])
        // Gone, then back under the same number: read again.
        #expect(directory.update(list: [2, 3], bundleID: read) == 0)
        #expect(directory.processes(for: "com.spotify.client") == [2])
        #expect(directory.update(list: [1, 2, 3], bundleID: read) == 1)
        #expect(directory.processes(for: "com.apple.Music") == [3])
    }

    @Test func aBundleIDThatCouldntBeReadIsTriedAgain() {
        var directory = AudioClientDirectory()
        var answer: String?
        #expect(directory.update(list: [7], bundleID: { _ in answer }) == 1)
        #expect(directory.processes(for: "com.apple.Music").isEmpty)
        answer = "com.apple.Music"
        #expect(directory.update(list: [7], bundleID: { _ in answer }) == 1)
        #expect(directory.processes(for: "com.apple.Music") == [7])
        #expect(directory.update(list: [7], bundleID: { _ in answer }) == 0)
    }
}
