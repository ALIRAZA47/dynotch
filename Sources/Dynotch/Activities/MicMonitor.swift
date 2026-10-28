import AudioToolbox
import CoreAudio
import CoreMediaIO
import Foundation

/// The microphone and cameras: whether any app is using them, for the on-air ring, and a
/// mute switch for the default input that works in every app.
@MainActor
final class MicMonitor: ObservableObject {
    static let shared = MicMonitor()

    @Published private(set) var isMuted = false
    @Published private(set) var micInUse = false
    @Published private(set) var cameraInUse = false
    /// There's an input device to mute.
    @Published private(set) var hasInput = false

    private let system = AudioObjectID(kAudioObjectSystemObject)
    private var input = AudioObjectID(kAudioObjectUnknown)
    private var inputAddresses: [AudioObjectPropertyAddress] = []
    private var processes: [AudioObjectID] = []
    private var cameras: [CMIOObjectID] = []
    private var isStarted = false
    private lazy var refreshListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.refresh() }
    }
    private lazy var cameraListener: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.refreshCameras() }
    }

    private static let defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private static let processListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private static let runningInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyIsRunningInput,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private static let processIDAddress = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyPID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private static let processInputDevicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyDevices,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain)
    private static let deviceRunningAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private static let muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain)
    private static let cameraListAddress = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    private static let cameraRunningAddress = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))

    private init() {}

    func start() {
        guard !isStarted else { return }
        isStarted = true
        var address = Self.defaultInputAddress
        AudioObjectAddPropertyListenerBlock(system, &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.bindDefaultInput() }
        }
        address = Self.processListAddress
        if AudioObjectHasProperty(system, &address) {
            AudioObjectAddPropertyListenerBlock(system, &address, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.bindProcesses() }
            }
        }
        var cameraAddress = Self.cameraListAddress
        CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &cameraAddress, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.bindCameras() }
        }
        bindDefaultInput()
        bindProcesses()
        bindCameras()
    }

    func toggleMute() {
        setMuted(!isMuted)
    }

    /// Mutes or unmutes the default input, and says so in the notch.
    func setMuted(_ muted: Bool) {
        guard input != kAudioObjectUnknown else {
            LiveActivityCenter.shared.post(LiveNotice(key: "mic", symbol: "mic.slash.fill", tint: .orange, text: "No mic"), for: 1.6)
            return
        }
        apply(muted: muted, to: input)
        refresh()
        let notice: LiveNotice
        if isMuted != muted {
            notice = LiveNotice(key: "mic", symbol: "mic.fill", tint: .orange, text: "",
                                detail: muted ? "This microphone can't be muted." : "This microphone can't be unmuted.")
        } else {
            notice = LiveNotice(key: "mic", symbol: muted ? "mic.slash.fill" : "mic.fill", tint: muted ? .red : .white,
                                text: muted ? "Muted" : "Mic on")
        }
        LiveActivityCenter.shared.post(notice, for: notice.detail == nil ? 1.6 : 3)
    }

    // MARK: Private

    private func bindDefaultInput() {
        let previous = input
        let wasMuted = isMuted
        for var address in inputAddresses {
            AudioObjectRemovePropertyListenerBlock(previous, &address, .main, refreshListener)
        }
        inputAddresses = []
        input = Self.readUInt32(system, Self.defaultInputAddress) ?? AudioObjectID(kAudioObjectUnknown)
        if input != kAudioObjectUnknown {
            // A mute set here follows you to the new microphone.
            if wasMuted, previous != kAudioObjectUnknown, previous != input {
                apply(muted: false, to: previous)
                apply(muted: true, to: input)
            }
            let watched = [Self.muteAddress, Self.deviceRunningAddress]
                + Self.volumeElements(of: input).map(Self.volumeAddress(element:))
            for property in watched {
                var address = property
                guard AudioObjectHasProperty(input, &address) else { continue }
                AudioObjectAddPropertyListenerBlock(input, &address, .main, refreshListener)
                inputAddresses.append(property)
            }
        }
        refresh()
    }

    private func bindProcesses() {
        for process in processes {
            for var address in [Self.runningInputAddress, Self.processInputDevicesAddress] {
                AudioObjectRemovePropertyListenerBlock(process, &address, .main, refreshListener)
            }
        }
        // Dynotch itself never counts.
        let ownID = UInt32(bitPattern: getpid())
        processes = Self.objectList(system, Self.processListAddress)
            .filter { Self.readUInt32($0, Self.processIDAddress) != ownID }
        for process in processes {
            for var address in [Self.runningInputAddress, Self.processInputDevicesAddress] {
                guard AudioObjectHasProperty(process, &address) else { continue }
                AudioObjectAddPropertyListenerBlock(process, &address, .main, refreshListener)
            }
        }
        refresh()
    }

    private func refresh() {
        var address = Self.processListAddress
        let inUse: Bool
        if AudioObjectHasProperty(system, &address) {
            // Per process, so a headset that's only playing doesn't count.
            inUse = processes.contains {
                (Self.readUInt32($0, Self.runningInputAddress) ?? 0) != 0 && Self.recordsFromDevice($0)
            }
        } else {
            inUse = (Self.readUInt32(input, Self.deviceRunningAddress) ?? 0) != 0
        }
        let muted = currentlyMuted()
        let present = input != kAudioObjectUnknown
        if micInUse != inUse { micInUse = inUse }
        if isMuted != muted { isMuted = muted }
        if hasInput != present { hasInput = present }
    }

    private func bindCameras() {
        for camera in cameras {
            var address = Self.cameraRunningAddress
            CMIOObjectRemovePropertyListenerBlock(camera, &address, .main, cameraListener)
        }
        cameras = Self.cameraList()
        for camera in cameras {
            var address = Self.cameraRunningAddress
            CMIOObjectAddPropertyListenerBlock(camera, &address, .main, cameraListener)
        }
        refreshCameras()
    }

    private func refreshCameras() {
        let running = cameras.contains { camera in
            var address = Self.cameraRunningAddress
            var running: UInt32 = 0, used: UInt32 = 0
            return CMIOObjectGetPropertyData(camera, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &running) == noErr
                && running != 0
        }
        if cameraInUse != running { cameraInUse = running }
    }

    // MARK: Muting

    /// Input levels to restore, by device UID, for microphones muted by turning them down.
    /// Kept across launches, so quitting while muted can't lose them.
    private var savedVolumes: [String: Double] {
        get { UserDefaults.dynotch.dictionary(forKey: "micSavedVolumes") as? [String: Double] ?? [:] }
        set { UserDefaults.dynotch.set(newValue, forKey: "micSavedVolumes") }
    }

    private func currentlyMuted() -> Bool {
        guard input != kAudioObjectUnknown else { return false }
        if Self.canSet(input, Self.muteAddress) {
            return (Self.readUInt32(input, Self.muteAddress) ?? 0) != 0
        }
        guard let uid = Self.uid(of: input), savedVolumes[uid] != nil else { return false }
        // Turned back up somewhere else, which counts as unmuting.
        if let volume = Self.volume(of: input), volume > 0.001 {
            savedVolumes[uid] = nil
            return false
        }
        return true
    }

    private func apply(muted: Bool, to device: AudioObjectID) {
        if Self.canSet(device, Self.muteAddress) {
            Self.write(UInt32(muted ? 1 : 0), to: device, Self.muteAddress)
            return
        }
        // No mute control: turn the input all the way down, then back to where it was.
        guard let uid = Self.uid(of: device) else { return }
        let elements = Self.volumeElements(of: device)
        if muted {
            if savedVolumes[uid] == nil { savedVolumes[uid] = Double(Self.volume(of: device) ?? 1) }
            elements.forEach { Self.write(Float32(0), to: device, Self.volumeAddress(element: $0)) }
        } else if let saved = savedVolumes[uid] {
            let level = Float32(saved > 0.05 ? saved : 0.75)
            elements.forEach { Self.write(level, to: device, Self.volumeAddress(element: $0)) }
            savedVolumes[uid] = nil
        }
    }

    // MARK: Core Audio

    private static func volumeAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeInput, mElement: element)
    }

    /// The input's own volume control, or its channels' when it has none.
    private static func volumeElements(of device: AudioObjectID) -> [AudioObjectPropertyElement] {
        if canSet(device, volumeAddress(element: kAudioObjectPropertyElementMain)) { return [kAudioObjectPropertyElementMain] }
        return [1, 2].filter { canSet(device, volumeAddress(element: $0)) }
    }

    private static func volume(of device: AudioObjectID) -> Float32? {
        volumeElements(of: device).compactMap { readFloat(device, volumeAddress(element: $0)) }.max()
    }

    private static func canSet(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var settable: DarwinBoolean = false
        return object != kAudioObjectUnknown && AudioObjectHasProperty(object, &address)
            && AudioObjectIsPropertySettable(object, &address, &settable) == noErr && settable.boolValue
    }

    private static func readUInt32(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> UInt32? {
        var address = address
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard object != kAudioObjectUnknown, AudioObjectHasProperty(object, &address),
              AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func readFloat(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Float32? {
        var address = address
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func write(_ value: UInt32, to object: AudioObjectID, _ address: AudioObjectPropertyAddress) {
        var address = address
        var value = value
        AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    private static func write(_ value: Float32, to object: AudioObjectID, _ address: AudioObjectPropertyAddress) {
        var address = address
        var value = value
        AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    private static func objectList(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> [AudioObjectID] {
        var address = address
        var size: UInt32 = 0
        guard AudioObjectHasProperty(object, &address),
              AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &list) == noErr else { return [] }
        return Array(list.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    /// Whether `process` records from an input device. Siri's listener (corespeechd) and audio taps
    /// run input on no device, and macOS's own microphone indicator leaves them out too.
    private static func recordsFromDevice(_ process: AudioObjectID) -> Bool {
        var address = processInputDevicesAddress
        guard AudioObjectHasProperty(process, &address) else { return true }
        return !objectList(process, processInputDevicesAddress).isEmpty
    }

    private static func uid(of device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    private static func cameraList() -> [CMIOObjectID] {
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var address = cameraListAddress
        var size: UInt32 = 0, used: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &list) == noErr else { return [] }
        return Array(list.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    // MARK: Snapshots

    func loadSample(muted: Bool, micInUse: Bool, cameraInUse: Bool) {
        isMuted = muted
        self.micInUse = micInUse
        self.cameraInUse = cameraInUse
        hasInput = true
    }
}
