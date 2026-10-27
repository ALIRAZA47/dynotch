import CoreBluetooth
import IOBluetooth
import SwiftUI

/// Battery levels of connected Bluetooth devices: AirPods (each bud and the case),
/// headphones, keyboards, mice, trackpads and controllers.
@MainActor
final class DeviceBatteryMonitor: NSObject, ObservableObject, CBCentralManagerDelegate {
    static let shared = DeviceBatteryMonitor()

    struct Device: Identifiable, Equatable {
        enum Kind {
            case earbuds, headphones, keyboard, mouse, trackpad, gamepad, speaker, other

            var symbol: String {
                switch self {
                case .earbuds: "airpodspro"
                case .headphones: "headphones"
                case .keyboard: "keyboard"
                case .mouse: "computermouse"
                case .trackpad: "rectangle.and.hand.point.up.left.filled"
                case .gamepad: "gamecontroller"
                case .speaker: "hifispeaker"
                case .other: "dot.radiowaves.right"
                }
            }

            /// Headphones first in the list of devices to connect.
            var connectOrder: Int {
                switch self {
                case .earbuds, .headphones: 0
                case .speaker: 1
                case .gamepad: 2
                case .keyboard, .mouse, .trackpad: 3
                case .other: 4
                }
            }
        }

        let id: String
        let name: String
        let kind: Kind
        var main: Int?
        var left: Int?
        var right: Int?
        var batteryCase: Int?

        var lowest: Int? { [main, left, right].compactMap { $0 }.min() }
    }

    /// A paired accessory that isn't connected, which the Batteries widget offers to connect.
    struct PairedDevice: Identifiable, Equatable {
        /// The Bluetooth address, as xx:xx:xx:xx:xx:xx.
        let id: String
        let name: String
        let kind: Device.Kind
    }

    /// A connect or disconnect in progress, or one that just failed.
    enum Connection: Equatable {
        case connecting, disconnecting
        case failed(String)
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var isAuthorized = CBManager.authorization == .allowedAlways
    /// Paired accessories that aren't connected, headphones first.
    @Published private(set) var paired: [PairedDevice] = []
    /// Keyed by Bluetooth address.
    @Published private(set) var connections: [String: Connection] = [:]

    private var central: CBCentralManager?
    private var connectNotification: IOBluetoothUserNotification?
    private var poll: Poll?
    private var isRefreshing = false
    private var lastRefresh = Date.distantPast
    private var warnedLow: Set<String> = []

    private override init() {
        super.init()
    }

    func start() {
        if isAuthorized { beginMonitoring() }
    }

    /// Asks for Bluetooth access, or opens System Settings if it was turned down before.
    func requestAccess() {
        switch CBManager.authorization {
        case .notDetermined:
            central = CBCentralManager(delegate: self, queue: .main)
        case .allowedAlways:
            isAuthorized = true
            beginMonitoring()
        default:
            CalendarService.openPrivacySettings("Privacy_Bluetooth")
        }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            self.isAuthorized = CBManager.authorization == .allowedAlways
            if self.isAuthorized { self.beginMonitoring() }
        }
    }

    /// Reads the levels with `system_profiler`, which takes a moment of CPU. Without `force`, a
    /// reading from the last half minute will do, as when the Batteries widget appears.
    func refresh(force: Bool = false) async {
        guard isAuthorized, !isRefreshing, force || Date.now.timeIntervalSince(lastRefresh) > 30 else { return }
        isRefreshing = true
        lastRefresh = .now
        defer { isRefreshing = false }
        let result = await Shell.run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"])
        guard result.status == 0 else { return }
        devices = Self.parse(result.output)
        paired = Self.parsePaired(result.output)
        settleConnections()
        warnAboutLowBatteries()
    }

    // MARK: Connecting

    /// Opens a connection to a paired device. The connect notification then announces it.
    func connect(_ device: PairedDevice) {
        guard connections[device.id] != .connecting else { return }
        guard let bluetooth = IOBluetoothDevice(addressString: device.id) else {
            fail(device.id, "Couldn't connect")
            return
        }
        connections[device.id] = .connecting
        let status = bluetooth.openConnection(self)
        guard status == kIOReturnSuccess else {
            fail(device.id, Self.message(for: status))
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(25))
            if connections[device.id] == .connecting { fail(device.id, "Didn't respond") }
        }
    }

    func disconnect(_ device: Device) {
        guard connections[device.id] != .disconnecting else { return }
        guard let bluetooth = IOBluetoothDevice(addressString: device.id), bluetooth.isConnected() else {
            fail(device.id, "Couldn't disconnect")
            return
        }
        connections[device.id] = .disconnecting
        guard bluetooth.closeConnection() == kIOReturnSuccess else {
            fail(device.id, "Couldn't disconnect")
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            await refresh(force: true)
            try? await Task.sleep(for: .seconds(10))
            if connections[device.id] == .disconnecting { fail(device.id, "Couldn't disconnect") }
        }
    }

    /// Called by IOBluetooth on the main thread when `openConnection(_:)` finishes.
    @objc private func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        guard let address = device.addressString.map(Self.normalized), connections[address] == .connecting else { return }
        guard status == kIOReturnSuccess else {
            fail(address, Self.message(for: status))
            return
        }
        // Stays "connecting" until system_profiler lists the device as connected.
        Task {
            for delay in [2.0, 4.0] {
                try? await Task.sleep(for: .seconds(delay))
                await refresh(force: true)
                if connections[address] != .connecting { return }
            }
            connections[address] = nil
        }
    }

    private func fail(_ address: String, _ message: String) {
        connections[address] = .failed(message)
        Task {
            try? await Task.sleep(for: .seconds(8))
            if connections[address] == .failed(message) { connections[address] = nil }
        }
    }

    /// Clears connects and disconnects that system_profiler shows have happened.
    private func settleConnections() {
        let connected = Set(devices.map(\.id))
        for (address, connection) in connections {
            switch connection {
            case .connecting where connected.contains(address), .disconnecting where !connected.contains(address):
                connections[address] = nil
            default:
                break
            }
        }
    }

    private static func message(for status: IOReturn) -> String {
        // 0x04 is the HCI page timeout: the device didn't answer.
        status == kIOReturnTimeout || status == 0x04 ? "Not in range" : "Couldn't connect"
    }

    /// IOBluetooth writes addresses as xx-xx-xx-xx-xx-xx; system_profiler as XX:XX:XX:XX:XX:XX.
    nonisolated private static func normalized(_ address: String) -> String {
        address.replacingOccurrences(of: "-", with: ":").uppercased()
    }

    // MARK: Private

    private func beginMonitoring() {
        guard connectNotification == nil else { return }
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))
        Task { await refresh(force: true) }
        poll = EnergyCoordinator.shared.schedule(.bluetoothBatteries) { [weak self] in
            Task { await self?.refresh(force: true) }
        }
    }

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
        let name = device.name ?? "Bluetooth device"
        Task {
            // Battery levels are reported a moment after the connection.
            try? await Task.sleep(for: .seconds(3))
            await refresh(force: true)
            guard AppSettings.shared.liveDevices else { return }
            let match = devices.first { $0.name == name }
            LiveActivityCenter.shared.post(LiveNotice(key: "device", symbol: match?.kind.symbol ?? "dot.radiowaves.right", tint: .white,
                                                      text: match?.lowest.map { "\($0)%" } ?? "", detail: "\(name) connected"), for: 3.5)
        }
    }

    @objc private func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        notification.unregister()
        Task { await refresh(force: true) }
    }

    private func warnAboutLowBatteries() {
        guard AppSettings.shared.lowBatteryAlerts else { return }
        for device in devices {
            guard let level = device.lowest else { continue }
            if level > 20 {
                warnedLow.remove(device.id)
            } else if level <= 15, warnedLow.insert(device.id).inserted {
                LiveActivityCenter.shared.post(LiveNotice(key: "device", symbol: device.kind.symbol, tint: .orange,
                                                          text: "\(level)%", detail: "\(device.name) is running low"), for: 5)
            }
        }
    }

    /// Reads `system_profiler SPBluetoothDataType -json`. Levels come as strings like "80%".
    nonisolated static func parse(_ json: String) -> [Device] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var devices: [Device] = []
        for controller in controllers {
            for entry in controller["device_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let properties = value as? [String: Any] else { continue }
                    devices.append(Device(id: properties["device_address"] as? String ?? name,
                                          name: name,
                                          kind: kind(name: name, minorType: properties["device_minorType"] as? String),
                                          main: percent(properties["device_batteryLevelMain"]),
                                          left: percent(properties["device_batteryLevelLeft"]),
                                          right: percent(properties["device_batteryLevelRight"]),
                                          batteryCase: percent(properties["device_batteryLevelCase"])))
                }
            }
        }
        return devices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Paired accessories that aren't connected, from the same output. Phones, watches and other Macs
    /// come without a minor type there, and connecting to them does nothing useful, so they're left out.
    nonisolated static func parsePaired(_ json: String) -> [PairedDevice] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var devices: [PairedDevice] = []
        for controller in controllers {
            for entry in controller["device_not_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let properties = value as? [String: Any],
                          let address = properties["device_address"] as? String else { continue }
                    let minorType = properties["device_minorType"] as? String
                    let kind = kind(name: name, minorType: minorType)
                    guard minorType != nil || kind != .other else { continue }
                    devices.append(PairedDevice(id: address.uppercased(), name: name, kind: kind))
                }
            }
        }
        return devices.sorted { ($0.kind.connectOrder, $0.name.lowercased()) < ($1.kind.connectOrder, $1.name.lowercased()) }
    }

    nonisolated private static func percent(_ value: Any?) -> Int? {
        (value as? String).flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) }
    }

    nonisolated private static func kind(name: String, minorType: String?) -> Device.Kind {
        let name = name.lowercased(), type = minorType?.lowercased() ?? ""
        if name.contains("airpods") || name.contains("buds") { return .earbuds }
        // Some speakers report themselves as headsets.
        if name.contains("speaker") { return .speaker }
        if type.contains("headphone") || type.contains("headset") || name.contains("beats") { return .headphones }
        if type.contains("keyboard") || name.contains("keyboard") { return .keyboard }
        if type.contains("mouse") || name.contains("mouse") { return .mouse }
        if type.contains("trackpad") || name.contains("trackpad") { return .trackpad }
        if type.contains("gamepad") || type.contains("joystick") || name.contains("controller") { return .gamepad }
        if type.contains("speaker") || name.contains("speaker") { return .speaker }
        return .other
    }

    // MARK: Snapshots

    func loadSample(_ devices: [Device], paired: [PairedDevice] = [], connections: [String: Connection] = [:]) {
        isAuthorized = true
        self.devices = devices
        self.paired = paired
        self.connections = connections
    }
}
