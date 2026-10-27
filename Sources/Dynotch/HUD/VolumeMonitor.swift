import AudioToolbox
import CoreAudio
import Foundation

/// Watches the default output device's volume and mute and shows them in the notch. It also changes
/// them, for the media keys when the system HUD is replaced and for scrolling over the artwork.
@MainActor
final class VolumeMonitor: ObservableObject {
    static let shared = VolumeMonitor()

    @Published private(set) var volume: Float = 0
    @Published private(set) var isMuted = false
    /// The volume changed a moment ago. The open player shows it over the artwork,
    /// since the closed notch's meter is out of sight then.
    @Published private(set) var isChanging = false

    private var device = AudioObjectID(kAudioObjectUnknown)
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var valueListener: AudioObjectPropertyListenerBlock?
    private var changeTask: Task<Void, Never>?

    private static var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    private static var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    private init() {}

    func start() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.bindDefaultDevice() }
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultDeviceAddress, .main, listener)
        deviceListener = listener
        bindDefaultDevice()
    }

    var symbol: String {
        if isMuted || volume <= 0 { return "speaker.slash.fill" }
        return volume < 0.34 ? "speaker.wave.1.fill" : volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }

    func setMuted(_ muted: Bool) {
        guard AudioObjectHasProperty(device, &Self.muteAddress) else { return }
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(device, &Self.muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    // MARK: Changing the volume

    /// The default output has a volume Dynotch can set. Some outputs, like many HDMI displays, don't.
    var canSetVolume: Bool { isSettable(&Self.volumeAddress) }
    var canMute: Bool { isSettable(&Self.muteAddress) }

    /// One press of a volume key: a sixteenth, or a sixty-fourth with ⇧⌥, as in macOS. Unmutes, and
    /// shows the meter even when the volume is already at either end.
    func step(up: Bool, fine: Bool) {
        if isMuted { setMuted(false) }
        writeVolume(MediaKeyTap.step(from: readVolume() ?? volume, up: up, fine: fine))
        reread()
        announce()
    }

    func toggleMute() {
        setMuted(!isMuted)
        reread()
        announce()
    }

    /// Scrolling over the open player's artwork. The open notch shows the level itself, so there's no meter.
    func nudge(by delta: Float) {
        guard delta != 0, canSetVolume else { return }
        if isMuted, delta > 0 { setMuted(false) }
        writeVolume(min(1, max(0, (readVolume() ?? volume) + delta)))
        reread()
        markChanging()
    }

    // MARK: Private

    private func isSettable(_ address: inout AudioObjectPropertyAddress) -> Bool {
        guard device != kAudioObjectUnknown, AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private func writeVolume(_ value: Float) {
        var value = Float32(value)
        AudioObjectSetPropertyData(device, &Self.volumeAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    /// Picks up a change Dynotch made, so the property listener doesn't announce it again.
    private func reread() {
        volume = readVolume() ?? volume
        isMuted = readMuted() ?? isMuted
    }

    private func announce() {
        LiveActivityCenter.shared.showMeter(key: "volume", symbol: symbol, level: isMuted ? 0 : Double(volume))
        markChanging()
    }

    private func markChanging() {
        if !isChanging { isChanging = true }
        changeTask?.cancel()
        changeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            self?.isChanging = false
        }
    }

    private func bindDefaultDevice() {
        if let valueListener, device != kAudioObjectUnknown {
            AudioObjectRemovePropertyListenerBlock(device, &Self.volumeAddress, .main, valueListener)
            AudioObjectRemovePropertyListenerBlock(device, &Self.muteAddress, .main, valueListener)
        }
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &Self.defaultDeviceAddress, 0, nil, &size, &id)
        device = id
        // Switching outputs (say, to AirPods) isn't a volume change worth announcing.
        volume = readVolume() ?? 0
        isMuted = readMuted() ?? false
        guard id != kAudioObjectUnknown else { return }

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.valuesChanged() }
        }
        if AudioObjectHasProperty(id, &Self.volumeAddress) {
            AudioObjectAddPropertyListenerBlock(id, &Self.volumeAddress, .main, listener)
        }
        if AudioObjectHasProperty(id, &Self.muteAddress) {
            AudioObjectAddPropertyListenerBlock(id, &Self.muteAddress, .main, listener)
        }
        valueListener = listener
    }

    private func valuesChanged() {
        let newVolume = readVolume() ?? volume
        let newMuted = readMuted() ?? isMuted
        guard abs(newVolume - volume) > 0.001 || newMuted != isMuted else { return }
        volume = newVolume
        isMuted = newMuted
        announce()
    }

    private func readVolume() -> Float? {
        guard device != kAudioObjectUnknown, AudioObjectHasProperty(device, &Self.volumeAddress) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &Self.volumeAddress, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private func readMuted() -> Bool? {
        guard device != kAudioObjectUnknown, AudioObjectHasProperty(device, &Self.muteAddress) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &Self.muteAddress, 0, nil, &size, &value)
        return status == noErr ? value != 0 : nil
    }

    // MARK: Snapshots

    func loadSample(volume: Float, changing: Bool) {
        self.volume = volume
        isMuted = false
        isChanging = changing
    }
}
