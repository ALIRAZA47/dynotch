import AppKit
import CoreAudio

/// The outputs macOS can play through, for the output picker beside the player. Choosing one makes
/// it the default output, as the Sound menu does. AirPlay speakers aren't Core Audio devices until
/// they're in use, so the picker adds AVKit's route picker for those.
@MainActor
final class AudioOutputs: ObservableObject {
    static let shared = AudioOutputs()

    struct Device: Identifiable, Equatable {
        let id: AudioObjectID
        let name: String
        /// kAudioDevicePropertyTransportType: built in, Bluetooth, USB...
        let transport: UInt32
        var isHeadphones = false

        var symbol: String {
            let name = name.lowercased()
            switch transport {
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
                if name.contains("airpods max") { return "airpodsmax" }
                if name.contains("airpods pro") { return "airpodspro" }
                if name.contains("airpods") { return "airpods" }
                if name.contains("beats") { return "beats.headphones" }
                return isHeadphones || name.contains("headphone") || name.contains("buds") ? "headphones" : "hifispeaker.fill"
            case kAudioDeviceTransportTypeAirPlay:
                return "airplayaudio"
            case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
                return "display"
            case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate:
                return "waveform"
            case kAudioDeviceTransportTypeBuiltIn:
                if isHeadphones { return "headphones" }
                return name.contains("macbook") ? "laptopcomputer" : "speaker.wave.2.fill"
            default:
                return isHeadphones ? "headphones" : "hifispeaker.fill"
            }
        }
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var currentID = AudioObjectID(kAudioObjectUnknown)
    /// The list of outputs is showing in place of the player.
    @Published var isPickerShown = false
    /// AirPlay's route picker has its list up. It hangs below the notch, which stays open meanwhile.
    @Published var isPresentingRoutes = false

    private var listener: AudioObjectPropertyListenerBlock?
    private var popoverObserver: NSObjectProtocol?

    private init() {}

    var current: Device? { devices.first { $0.id == currentID } }

    func start() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
        self.listener = listener
        // The route picker's delegate should report the end of its list, but if it doesn't, its popover closing will.
        popoverObserver = NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: nil,
                                                                 queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.isPresentingRoutes == true { self?.isPresentingRoutes = false }
            }
        }
        reload()
    }

    func select(_ device: Device) {
        guard device.id != currentID else { return }
        // Alerts that played through the old output follow to the new one, as when the Sound menu switches.
        let alertsFollow = Self.device(kAudioHardwarePropertyDefaultSystemOutputDevice) == currentID
        Self.setDevice(device.id, kAudioHardwarePropertyDefaultOutputDevice)
        if alertsFollow, Self.uint32(device.id, kAudioDevicePropertyDeviceCanBeDefaultSystemDevice,
                                     scope: kAudioDevicePropertyScopeOutput) == 1 {
            Self.setDevice(device.id, kAudioHardwarePropertyDefaultSystemOutputDevice)
        }
        reload()
    }

    func reload() {
        // The Mac's own outputs first, then the rest by name.
        let found = Self.objectList(kAudioHardwarePropertyDevices).compactMap(Self.outputDevice).sorted { a, b in
            let aBuiltIn = a.transport == kAudioDeviceTransportTypeBuiltIn, bBuiltIn = b.transport == kAudioDeviceTransportTypeBuiltIn
            if aBuiltIn != bBuiltIn { return aBuiltIn }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        if found != devices { devices = found }
        let current = Self.device(kAudioHardwarePropertyDefaultOutputDevice)
        if current != currentID { currentID = current }
    }

    // MARK: Core Audio

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// A device that can play sound and be the default output: it has output streams and isn't hidden.
    private static func outputDevice(_ id: AudioObjectID) -> Device? {
        var streams = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &size) == noErr, size > 0,
              uint32(id, kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: kAudioDevicePropertyScopeOutput) == 1,
              uint32(id, kAudioDevicePropertyIsHidden) != 1,
              let name = string(id, kAudioObjectPropertyName) else { return nil }
        // Older Macs switch the built-in output's source to headphones instead of adding a device.
        let headphones: UInt32 = 0x6864_706E // 'hdpn'
        let source = uint32(id, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput)
        return Device(id: id, name: name, transport: uint32(id, kAudioDevicePropertyTransportType) ?? 0,
                      isHeadphones: source == headphones || name.localizedCaseInsensitiveContains("headphone"))
    }

    private static func objectList(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = address(selector)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &list) == noErr else { return [] }
        return list
    }

    private static func device(_ selector: AudioObjectPropertySelector) -> AudioObjectID {
        objectList(selector).first ?? AudioObjectID(kAudioObjectUnknown)
    }

    private static func setDevice(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) {
        var address = address(selector)
        var value = id
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                   UInt32(MemoryLayout<AudioObjectID>.size), &value)
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = address(selector, scope: scope)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    // MARK: Snapshots

    /// Made-up outputs, playing through AirPods.
    func loadSample(pickerShown: Bool) {
        devices = [
            Device(id: 1, name: "MacBook Pro Speakers", transport: kAudioDeviceTransportTypeBuiltIn),
            Device(id: 2, name: "AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth),
            Device(id: 3, name: "Studio Display Speakers", transport: kAudioDeviceTransportTypeUSB),
        ]
        currentID = 2
        isPickerShown = pickerShown
    }
}
