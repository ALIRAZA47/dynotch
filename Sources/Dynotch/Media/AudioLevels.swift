import AppKit
import Combine
import CoreAudio

/// Live levels for the equalizer bars, from a Core Audio process tap on the music app (macOS 14.2
/// and later). The tap runs only while the Live equalizer setting is on, music plays and some bars
/// are on screen; otherwise, and until sound arrives, the bars stay decorative.
@MainActor
final class AudioLevels: ObservableObject {
    static let shared = AudioLevels()
    static let bandCount = 4

    static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    /// Levels from 0 to 1, lowest band first, while the tap hears the music. nil leaves the bars decorative.
    @Published private(set) var bands: [Float]?
    @Published private(set) var permission = AudioCapturePermission.status

    private var isStarted = false
    /// AudioBars on screen.
    private var viewers = 0
    private var tap: LevelTap?
    /// What the running or starting tap listens to; nil when there's none.
    private var tapBundleID: String?
    private var tapProcesses: [AudioObjectID] = []
    private var failedAt: Date?
    /// Bumped on every start and stop, so a tap that finishes starting late, or still delivers
    /// after it's stopped, is ignored.
    private var generation = 0
    private var stopTask: Task<Void, Never>?
    private var listener: AudioObjectPropertyListenerBlock?
    /// The audio clients' bundle IDs, so a change to the list reads only the clients new to it.
    private var directory = AudioClientDirectory()
    /// `directory` matches the list. It's read again only when the tap is wanted and it doesn't,
    /// never for a Now Playing change alone.
    private var listIsCurrent = false
    /// A change to the list waits for the rest of its burst.
    private var listChange: Task<Void, Never>?
    static let listDebounce: Duration = .milliseconds(250)
    private var cancellables = Set<AnyCancellable>()
    /// Creating, starting and destroying the tap can each take a moment.
    private static let control = DispatchQueue(label: "app.dynotch.equalizer.control", qos: .userInitiated)

    private init() {}

    func start() {
        isStarted = true
        let settings = AppSettings.shared
        // Turning the setting on is when to ask for the permission, never at launch.
        settings.$liveEqualizer
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] enabled in
                if enabled { self?.requestPermission() }
            }
            .store(in: &cancellables)
        Publishers.Merge(settings.$liveEqualizer.map { _ in () }, NowPlayingService.shared.objectWillChange.map { _ in () })
            // @Published fires before the value changes; read it on the next turn.
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.update() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refreshPermission() }
            .store(in: &cancellables)

        // A player that starts making sound shows up as a new process object; a new output device
        // gets a fresh tap.
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, address in
            let selector = address.pointee.mSelector
            MainActor.assumeIsolated { self?.audioSystemChanged(selector) }
        }
        for selector in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                      mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
        self.listener = listener
        update()
    }

    func addViewer() {
        viewers += 1
        update()
    }

    func removeViewer() {
        viewers = max(0, viewers - 1)
        update()
    }

    /// Asks for "System Audio Recording Only", or opens System Settings if it was turned down.
    func requestPermission() {
        switch AudioCapturePermission.status {
        case .denied:
            CalendarService.openPrivacySettings("Privacy_AudioCapture")
        case .notDetermined:
            AudioCapturePermission.request { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPermission() }
            }
        case .granted, .unknown:
            refreshPermission()
        }
    }

    // MARK: Private

    private func refreshPermission() {
        let status = AudioCapturePermission.status
        if status != permission { permission = status }
        update()
    }

    private func audioSystemChanged(_ selector: AudioObjectPropertySelector) {
        guard selector == kAudioHardwarePropertyProcessObjectList else {
            if selector == kAudioHardwarePropertyDefaultOutputDevice, tapBundleID != nil { stopTap() }
            update()
            return
        }
        // Clients come and go in bursts, and starting or stopping the tap is one of them: Dynotch
        // becomes a client itself. That reads one new bundle ID, finds the player's clients as they
        // were and leaves the tap alone, so it can't go round.
        listIsCurrent = false
        listChange?.cancel()
        listChange = Task { [weak self] in
            try? await Task.sleep(for: Self.listDebounce)
            guard !Task.isCancelled else { return }
            self?.listChange = nil
            self?.update()
        }
    }

    private func update() {
        guard isStarted else { return }
        let media = NowPlayingService.shared
        let settings = AppSettings.shared
        guard settings.liveEqualizer, Self.isSupported, let bundleID = media.player?.bundleID else {
            stopTap()
            return
        }
        // It may have been granted in System Settings while Dynotch stayed in the background.
        if permission != .granted, permission != .unknown {
            let status = AudioCapturePermission.status
            if status != permission { permission = status }
        }
        // Not determined means the prompt went unanswered; it's asked again when the setting is turned on.
        guard permission == .granted || permission == .unknown else {
            stopTap()
            return
        }
        guard media.isPlaying, viewers > 0 else {
            // Not right now: a notice covering the bars, a pause or a skip shouldn't tear the tap down.
            if tapBundleID != nil, stopTask == nil {
                stopTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled else { return }
                    self?.stopTask = nil
                    self?.stopTap()
                }
            }
            return
        }
        stopTask?.cancel()
        stopTask = nil
        if !listIsCurrent {
            directory.update(list: Self.processList(), bundleID: Self.bundleID(of:))
            listIsCurrent = true
        }
        let processes = directory.processes(for: bundleID)
        guard bundleID != tapBundleID || processes != tapProcesses else { return }
        stopTap()
        // A player only gets a process object once it makes sound; the process list listener tries again then.
        guard !processes.isEmpty else { return }
        if let failedAt, Date.now.timeIntervalSince(failedAt) < 10 { return }
        startTap(bundleID: bundleID, processes: processes)
    }

    private func startTap(bundleID: String, processes: [AudioObjectID]) {
        guard #available(macOS 14.2, *) else { return }
        generation += 1
        let generation = generation
        tapBundleID = bundleID
        tapProcesses = processes
        let bandCount = Self.bandCount
        let deliver: @Sendable (SpectrumAnalyzer.Output) -> Void = { output in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AudioLevels.shared.receive(output, generation: generation) }
            }
        }
        Self.control.async {
            let tap = try? LevelTap(processes: processes, bands: bandCount, deliver: deliver)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AudioLevels.shared.tapStarted(tap, generation: generation) }
            }
        }
    }

    private func tapStarted(_ tap: LevelTap?, generation: Int) {
        guard generation == self.generation else {
            if let tap { Self.control.async { tap.stop() } }
            return
        }
        guard let tap else {
            // Try again in a while rather than on every change.
            failedAt = .now
            tapBundleID = nil
            tapProcesses = []
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10.5))
                self?.update()
            }
            return
        }
        failedAt = nil
        self.tap = tap
    }

    private func stopTap() {
        stopTask?.cancel()
        stopTask = nil
        if bands != nil { bands = nil }
        guard tapBundleID != nil || tap != nil else { return }
        generation += 1
        tapBundleID = nil
        tapProcesses = []
        guard let tap else { return }
        self.tap = nil
        Self.control.async { tap.stop() }
    }

    private func receive(_ output: SpectrumAnalyzer.Output, generation: Int) {
        guard generation == self.generation else { return }
        let next = output.isSilent ? nil : output.bands
        if next != bands { bands = next }
    }

    /// Every audio process object on the Mac.
    private static func processList() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &list) == noErr else { return [] }
        return Array(list.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func bundleID(of process: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String? ?? ""
    }

    // MARK: Snapshots

    func loadSample(_ bands: [Float]?) {
        self.bands = bands
    }
}

/// The audio clients' bundle IDs, each read once, when its process object first shows up.
struct AudioClientDirectory {
    private var order: [AudioObjectID] = []
    /// Empty for a client without one.
    private var bundleIDs: [AudioObjectID: String] = [:]

    /// Takes the list as it is now, reading the bundle ID of only the clients new to it. One that
    /// couldn't be read is tried again next time. Returns how many were read.
    @discardableResult
    mutating func update(list: [AudioObjectID], bundleID: (AudioObjectID) -> String?) -> Int {
        var next: [AudioObjectID: String] = [:]
        var reads = 0
        for process in list where next[process] == nil {
            if let known = bundleIDs[process] {
                next[process] = known
            } else {
                reads += 1
                if let id = bundleID(process) { next[process] = id }
            }
        }
        order = list
        bundleIDs = next
        return reads
    }

    /// The player's clients, in the list's order: the app itself and any helpers whose bundle IDs
    /// start with its own.
    func processes(for bundleID: String) -> [AudioObjectID] {
        var seen: Set<AudioObjectID> = []
        return order.filter { process in
            guard let id = bundleIDs[process], seen.insert(process).inserted else { return false }
            return id == bundleID || id.hasPrefix(bundleID + ".")
        }
    }
}

/// A private process tap on the player, in a private aggregate device whose IO proc feeds a
/// SpectrumAnalyzer. Create and stop it off the main thread.
final class LevelTap: @unchecked Sendable {
    struct Failure: Error {
        let step: String
        let status: OSStatus
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "app.dynotch.equalizer.io", qos: .userInteractive)

    @available(macOS 14.2, *)
    init(processes: [AudioObjectID], bands: Int, deliver: @escaping @Sendable (SpectrumAnalyzer.Output) -> Void) throws {
        do {
            let description = CATapDescription(stereoMixdownOfProcesses: processes)
            description.uuid = UUID()
            description.name = "Dynotch equalizer"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            try Self.check("create the tap", AudioHardwareCreateProcessTap(description, &tapID))

            var format = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            try Self.check("read the tap's format", AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format))
            guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32, format.mSampleRate > 0 else {
                throw Failure(step: "use the tap's format", status: kAudioHardwareUnsupportedOperationError)
            }

            // Only the tap, no hardware: adding an output device could also open its microphone.
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Dynotch equalizer",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]],
            ]
            try Self.check("create the aggregate device",
                           AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID))

            let analyzer = SpectrumAnalyzer(sampleRate: format.mSampleRate, bands: bands)
            try Self.check("add the IO proc", AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
                if let output = analyzer.process(input) { deliver(output) }
            })
            try Self.check("start", AudioDeviceStart(aggregateID, procID))
        } catch {
            stop()
            throw error
        }
    }

    /// Stops the IO and destroys the aggregate device and the tap.
    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private static func check(_ step: String, _ status: OSStatus) throws {
        guard status == noErr else { throw Failure(step: step, status: status) }
    }
}

/// "System Audio Recording Only", the permission a process tap needs. There's no public API to read
/// or request it, so this asks TCC directly, as other audio tools do. Where that isn't possible
/// the status is unknown, and macOS asks when the tap first runs.
enum AudioCapturePermission {
    enum Status {
        case granted, denied, notDetermined, unknown
    }

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let library = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        library.flatMap { dlsym($0, name) }
    }

    static var status: Status {
        guard let symbol = symbol("TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(symbol, to: Preflight.self)(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .notDetermined
        }
    }

    /// Shows the system prompt. `completion` runs on the main queue.
    static func request(_ completion: @escaping @Sendable (Bool) -> Void) {
        guard let symbol = symbol("TCCAccessRequest") else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        unsafeBitCast(symbol, to: Request.self)(service, nil) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }
}
