import Combine
import CoreBluetooth
import IOBluetooth
import SwiftUI

/// The part of reading batteries that touches the Mac, apart so that no test runs `system_profiler`
/// or reaches a device.
struct BluetoothMac {
    /// What asking a device to disconnect came to.
    enum Disconnect: Sendable {
        case closed, notConnected, failed
    }

    var isAuthorized: @MainActor () -> Bool
    /// `system_profiler SPBluetoothDataType -json`, or nil when it failed or ran out of time.
    var readProfile: @Sendable () async -> String?
    /// Starts IOBluetooth's connect notifications.
    var watchConnections: @MainActor (DeviceBatteryMonitor) -> Void
    /// Closes the connection to the device at an address, off the main thread: it waits for the device to answer.
    var disconnect: @Sendable (_ address: String) async -> Disconnect
    var lowBatteryAlerts: @MainActor () -> Bool
    /// Fires after the low-battery alerts setting changes.
    var alertsChanged: AnyPublisher<Void, Never>
    var now: @MainActor () -> Date

    private static let deviceQueue = DispatchQueue(label: "app.dynotch.bluetooth.devices", qos: .userInitiated)

    @MainActor static let live = BluetoothMac(
        isAuthorized: { CBManager.authorization == .allowedAlways },
        readProfile: {
            let result = await Shell.run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"])
            return result.status == 0 ? result.output : nil
        },
        watchConnections: { $0.registerForConnects() },
        disconnect: { address in
            await withCheckedContinuation { continuation in
                deviceQueue.async {
                    guard let device = IOBluetoothDevice(addressString: address), device.isConnected() else {
                        continuation.resume(returning: .notConnected)
                        return
                    }
                    continuation.resume(returning: device.closeConnection() == kIOReturnSuccess ? .closed : .failed)
                }
            }
        },
        lowBatteryAlerts: { AppSettings.shared.lowBatteryAlerts },
        // @Published says so before the value changes, and once on subscribing.
        alertsChanged: AppSettings.shared.$lowBatteryAlerts.dropFirst().removeDuplicates().map { _ in () }
            .receive(on: RunLoop.main).eraseToAnyPublisher(),
        now: { .now })
}

/// Battery levels of connected Bluetooth devices: AirPods (each bud and the case),
/// headphones, keyboards, mice, trackpads and controllers.
///
/// Nothing announces a level, so they're read with `system_profiler`, which makes the Bluetooth
/// daemon list every device. That happens every couple of minutes while a view showing them is on
/// screen, every ten or more while only low-battery alerts want them, never otherwise; and once,
/// a few seconds after a burst of connects and disconnects.
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
    @Published private(set) var isAuthorized = false
    /// Paired accessories that aren't connected, headphones first.
    @Published private(set) var paired: [PairedDevice] = []
    /// Keyed by Bluetooth address.
    @Published private(set) var connections: [String: Connection] = [:]

    /// How long after the last connect or disconnect to read the levels, which a device reports a
    /// moment after connecting anyway.
    var settleDelay: Duration = .seconds(3)
    /// A view showing levels that comes on screen re-reads ones older than this.
    static let freshEnough: TimeInterval = 60

    private let mac: BluetoothMac
    private let energy: EnergyCoordinator
    private var central: CBCentralManager?
    private var connectNotification: IOBluetoothUserNotification?
    private var isMonitoring = false
    private var poll: Poll?
    private var alertsSubscription: AnyCancellable?
    /// Views showing device batteries on screen.
    private var viewers = 0
    private var isRefreshing = false
    /// A forced refresh was asked for while one ran.
    private var refreshAgain = false
    private var lastRefresh = Date.distantPast
    private var settleTask: Task<Void, Never>?
    /// Devices that connected since the levels were last read, to announce once they are.
    private var arrivals: [String] = []
    private var warnedLow: Set<String> = []

    /// The app uses `shared`; tests make their own with a stand-in Mac.
    init(mac: BluetoothMac? = nil, energy: EnergyCoordinator? = nil) {
        let mac = mac ?? .live
        self.mac = mac
        self.energy = energy ?? .shared
        super.init()
        isAuthorized = mac.isAuthorized()
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
            self.isAuthorized = self.mac.isAuthorized()
            if self.isAuthorized { self.beginMonitoring() }
        }
    }

    /// Reads the levels with `system_profiler`, which takes a moment of CPU. Without `force`, a
    /// reading younger than `maxAge` will do, and one already running is enough. A forced one asked
    /// for while one runs comes after it, since a device may have come or gone in between.
    func refresh(force: Bool = false, maxAge: TimeInterval = 30) async {
        guard isAuthorized else { return }
        guard !isRefreshing else {
            if force { refreshAgain = true }
            return
        }
        guard force || mac.now().timeIntervalSince(lastRefresh) > maxAge else { return }
        isRefreshing = true
        lastRefresh = mac.now()
        // Shell.run gives up on a command that hangs, so this always comes back.
        let output = await mac.readProfile()
        isRefreshing = false
        if let output {
            devices = Self.parse(output)
            paired = Self.parsePaired(output)
            settleConnections()
            warnAboutLowBatteries()
        }
        if refreshAgain {
            refreshAgain = false
            await refresh(force: true)
        }
    }

    // MARK: Who needs the levels

    /// A view showing device batteries came on screen: the Batteries widget or the Control
    /// section's strip. While any is, the levels are polled every couple of minutes, and one
    /// arriving re-reads levels older than `freshEnough`. Pair with `removeViewer()`.
    @discardableResult
    func addViewer() -> Task<Void, Never>? {
        viewers += 1
        guard viewers == 1 else { return nil }
        updatePolling()
        guard isMonitoring else { return nil }
        return Task { await refresh(maxAge: Self.freshEnough) }
    }

    func removeViewer() {
        guard viewers > 0 else { return }
        viewers -= 1
        if viewers == 0 { updatePolling() }
    }

    /// How often the levels are read for these needs, or nil for not at all.
    static func cadence(viewers: Int, lowBatteryAlerts: Bool) -> Cadence? {
        viewers > 0 ? .bluetoothBatteries : lowBatteryAlerts ? .bluetoothBatteryAlerts : nil
    }

    /// How often the levels are being read right now, or nil.
    var pollCadence: Cadence? { poll?.cadence }

    private func updatePolling() {
        let wanted = isMonitoring ? Self.cadence(viewers: viewers, lowBatteryAlerts: mac.lowBatteryAlerts()) : nil
        switch (poll, wanted) {
        case let (nil, cadence?):
            poll = energy.schedule(cadence) { [weak self] in
                Task { await self?.refresh() }
            }
        case let (current?, nil):
            current.cancel()
            poll = nil
        case let (current?, cadence?):
            current.change(to: cadence)
        case (nil, nil):
            break
        }
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

    /// Closing a connection waits for the device to answer, so it happens off the main thread.
    @discardableResult
    func disconnect(_ device: Device) -> Task<Void, Never>? {
        guard connections[device.id] != .disconnecting else { return nil }
        let address = device.id
        connections[address] = .disconnecting
        let close = mac.disconnect
        return Task {
            guard await close(address) == .closed else {
                fail(address, "Couldn't disconnect")
                return
            }
            // The disconnect notification reads the levels too; this is in case it doesn't come.
            deviceCameOrWent()
            try? await Task.sleep(for: .seconds(12))
            if connections[address] == .disconnecting { fail(address, "Couldn't disconnect") }
        }
    }

    /// Called by IOBluetooth on the main thread when `openConnection(_:)` finishes.
    @objc private func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        guard let address = device.addressString.map(Self.normalized), connections[address] == .connecting else { return }
        guard status == kIOReturnSuccess else {
            fail(address, Self.message(for: status))
            return
        }
        // Stays "connecting" until system_profiler lists the device as connected. The connect
        // notification reads the levels; once more if it's slow to show up there.
        deviceCameOrWent()
        Task {
            try? await Task.sleep(for: .seconds(8))
            if connections[address] == .connecting { await refresh(force: true) }
            if connections[address] == .connecting { connections[address] = nil }
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

    /// Reads the levels once, then as often as `cadence(viewers:lowBatteryAlerts:)` says.
    @discardableResult
    func beginMonitoring() -> Task<Void, Never>? {
        guard !isMonitoring else { return nil }
        isMonitoring = true
        mac.watchConnections(self)
        alertsSubscription = mac.alertsChanged.sink { [weak self] in self?.updatePolling() }
        updatePolling()
        return Task { await refresh(force: true) }
    }

    /// For `BluetoothMac.live`.
    func registerForConnects() {
        guard connectNotification == nil else { return }
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))
    }

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
        arrivals.append(device.name ?? "Bluetooth device")
        deviceCameOrWent()
    }

    @objc private func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        notification.unregister()
        deviceCameOrWent()
    }

    /// A device connected or disconnected. A mouse or earbuds waking can send several in a row, so
    /// the levels are read once, `settleDelay` after the last of them.
    @discardableResult
    func deviceCameOrWent() -> Task<Void, Never> {
        settleTask?.cancel()
        let delay = settleDelay
        let task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.settleTask = nil
            await self.refresh(force: true)
            self.announceArrivals()
        }
        settleTask = task
        return task
    }

    private func announceArrivals() {
        let names = arrivals
        arrivals = []
        guard !names.isEmpty, AppSettings.shared.liveDevices else { return }
        for name in names {
            let match = devices.first { $0.name == name }
            LiveActivityCenter.shared.post(LiveNotice(key: "device", symbol: match?.kind.symbol ?? "dot.radiowaves.right", tint: .white,
                                                      text: match?.lowest.map { "\($0)%" } ?? "", detail: "\(name) connected",
                                                      timing: .perishes), for: 3.5)
        }
    }

    private func warnAboutLowBatteries() {
        guard mac.lowBatteryAlerts() else { return }
        for device in devices {
            guard let level = device.lowest else { continue }
            if level > 20 {
                warnedLow.remove(device.id)
            } else if level <= 15, warnedLow.insert(device.id).inserted {
                LiveActivityCenter.shared.post(LiveNotice(key: "device", symbol: device.kind.symbol, tint: .orange,
                                                          text: "\(level)%", detail: "\(device.name) is running low",
                                                          recall: .whole), for: 5)
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

    func loadSample(_ devices: [Device], paired: [PairedDevice] = [], connections: [String: Connection] = [:],
                    isAuthorized: Bool = true) {
        self.isAuthorized = isAuthorized
        self.devices = devices
        self.paired = paired
        self.connections = connections
    }
}
