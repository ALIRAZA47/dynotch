import AudioToolbox
import CoreAudio
import Foundation

/// Watches the default output device's volume and mute, and shows them in the notch.
@MainActor
final class VolumeMonitor: ObservableObject {
    static let shared = VolumeMonitor()

    @Published private(set) var volume: Float = 0
    @Published private(set) var isMuted = false

    private var device = AudioObjectID(kAudioObjectUnknown)
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var valueListener: AudioObjectPropertyListenerBlock?

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

    // MARK: Private

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
        LiveActivityCenter.shared.showMeter(key: "volume", symbol: symbol, level: isMuted ? 0 : Double(volume))
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
}
