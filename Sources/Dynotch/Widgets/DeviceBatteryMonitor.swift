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

    @Published private(set) var devices: [Device] = []
    @Published private(set) var isAuthorized = CBManager.authorization == .allowedAlways

    private var central: CBCentralManager?
    private var connectNotification: IOBluetoothUserNotification?
    private var timer: Timer?
    private var isRefreshing = false
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

    func refresh() async {
        guard isAuthorized, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let result = await Shell.run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"])
        guard result.status == 0 else { return }
        devices = Self.parse(result.output)
        warnAboutLowBatteries()
    }

    // MARK: Private

    private func beginMonitoring() {
        guard connectNotification == nil else { return }
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))
        Task { await refresh() }
        let timer = Timer(timeInterval: 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refresh() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
        let name = device.name ?? "Bluetooth device"
        Task {
            // Battery levels are reported a moment after the connection.
            try? await Task.sleep(for: .seconds(3))
            await refresh()
            guard AppSettings.shared.liveDevices else { return }
            let match = devices.first { $0.name == name }
            LiveActivityCenter.shared.post(LiveNotice(key: "device", symbol: match?.kind.symbol ?? "dot.radiowaves.right", tint: .white,
                                                      text: match?.lowest.map { "\($0)%" } ?? "", detail: "\(name) connected"), for: 3.5)
        }
    }

    @objc private func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        notification.unregister()
        Task { await refresh() }
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

    nonisolated private static func percent(_ value: Any?) -> Int? {
        (value as? String).flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) }
    }

    nonisolated private static func kind(name: String, minorType: String?) -> Device.Kind {
        let name = name.lowercased(), type = minorType?.lowercased() ?? ""
        if name.contains("airpods") || name.contains("buds") { return .earbuds }
        if type.contains("headphone") || type.contains("headset") || name.contains("beats") { return .headphones }
        if type.contains("keyboard") || name.contains("keyboard") { return .keyboard }
        if type.contains("mouse") || name.contains("mouse") { return .mouse }
        if type.contains("trackpad") || name.contains("trackpad") { return .trackpad }
        if type.contains("gamepad") || type.contains("joystick") || name.contains("controller") { return .gamepad }
        if type.contains("speaker") || name.contains("speaker") { return .speaker }
        return .other
    }

    // MARK: Snapshots

    func loadSample(_ devices: [Device]) {
        isAuthorized = true
        self.devices = devices
    }
}
