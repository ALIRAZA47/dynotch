import SwiftUI

/// The Mac's battery plus every connected Bluetooth device that reports one. Paired devices that
/// aren't connected fill any room left, headphones first, each with a Connect button.
struct DevicesWidget: View {
    @ObservedObject private var power = PowerMonitor.shared
    @ObservedObject private var monitor = DeviceBatteryMonitor.shared
    @Environment(\.isSnapshot) private var isSnapshot

    /// Looked up once: `Host` can be slow to answer.
    private static let macName = Host.current().localizedName ?? "This Mac"

    var body: some View {
        WidgetCard(title: "Batteries", symbol: "battery.75percent") {
            if monitor.isAuthorized {
                GeometryReader { proxy in
                    // As many paired devices as fit, down to none.
                    ViewThatFits(in: .vertical) {
                        ForEach(Array((0...min(monitor.paired.count, 3)).reversed()), id: \.self) { count in
                            rows(paired: count, compact: proxy.size.width < 160)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    macRow
                    Spacer(minLength: 0)
                    PillButton(title: "Show Bluetooth devices", symbol: "dot.radiowaves.right", action: monitor.requestAccess)
                        .frame(maxWidth: .infinity)
                    Spacer(minLength: 0)
                }
            }
        }
        .onAppear { Task { await monitor.refresh() } }
    }

    private func rows(paired count: Int, compact: Bool) -> some View {
        let connected = monitor.devices.filter { $0.lowest != nil || $0.batteryCase != nil }
        return VStack(alignment: .leading, spacing: 8) {
            macRow
            ForEach(connected.prefix(3)) { device in
                connectedRow(device)
            }
            if connected.isEmpty, !power.hasBattery, monitor.paired.isEmpty {
                Text("No Bluetooth devices connected")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.notchTertiary)
            }
            ForEach(monitor.paired.prefix(count)) { device in
                PairedRow(device: device, connection: monitor.connections[device.id], compact: compact, isSnapshot: isSnapshot) {
                    monitor.connect(device)
                }
            }
        }
    }

    @ViewBuilder
    private var macRow: some View {
        if power.hasBattery {
            DeviceRow(symbol: "laptopcomputer", name: isSnapshot ? "MacBook Pro" : Self.macName,
                      detail: power.isCharging ? "Charging" : power.isPluggedIn ? "Plugged in" : nil,
                      level: power.level, charging: power.isCharging || power.isPluggedIn)
        }
    }

    private func connectedRow(_ device: DeviceBatteryMonitor.Device) -> some View {
        let status = Status(monitor.connections[device.id])
        return DeviceRow(symbol: device.kind.symbol, name: device.name, detail: status?.text ?? budsDetail(device),
                         detailTint: status?.tint ?? Color.notchTertiary,
                         level: device.lowest ?? device.batteryCase ?? 0, charging: false)
            .contextMenu {
                Button("Disconnect") { monitor.disconnect(device) }
                    .disabled(monitor.connections[device.id] == .disconnecting)
            }
    }

    private func budsDetail(_ device: DeviceBatteryMonitor.Device) -> String? {
        let parts = [device.left.map { "L \($0)%" }, device.right.map { "R \($0)%" }, device.batteryCase.map { "Case \($0)%" }]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// What a row says while it connects or disconnects, or after that failed.
private struct Status {
    let text: String
    let tint: Color

    init?(_ connection: DeviceBatteryMonitor.Connection?) {
        switch connection {
        case .connecting: (text, tint) = ("Connecting…", Color.notchTertiary)
        case .disconnecting: (text, tint) = ("Disconnecting…", Color.notchTertiary)
        case .failed(let message): (text, tint) = (message, Color.orange)
        case nil: return nil
        }
    }
}

private struct DeviceRow: View {
    let symbol: String
    let name: String
    let detail: String?
    var detailTint = Color.notchTertiary
    let level: Int
    let charging: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 20)
                .foregroundStyle(Color.notchSecondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(name)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if charging {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.green)
                    }
                    Text("\(level)%")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(color)
                }
                if let detail {
                    Text(detail)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(detailTint)
                        .lineLimit(1)
                } else {
                    LevelBar(level: Double(level) / 100, color: color)
                        .frame(height: 3)
                }
            }
        }
    }

    private var color: Color {
        charging ? .green : level <= 10 ? .red : level <= 20 ? .orange : .white
    }
}

/// A paired device that isn't connected, with a button to connect it. In a narrow widget the
/// button is just a symbol.
private struct PairedRow: View {
    let device: DeviceBatteryMonitor.PairedDevice
    let connection: DeviceBatteryMonitor.Connection?
    let compact: Bool
    let isSnapshot: Bool
    let connect: () -> Void

    var body: some View {
        let status = Status(connection)
        HStack(spacing: 8) {
            Image(systemName: device.kind.symbol)
                .font(.system(size: 13))
                .frame(width: 20)
                .foregroundStyle(Color.notchTertiary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(device.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.notchSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if connection == .connecting {
                        spinner
                            .frame(width: 16, height: 16)
                    } else {
                        ConnectButton(title: status == nil ? "Connect" : "Retry",
                                      symbol: status == nil ? "link" : "arrow.clockwise", compact: compact, action: connect)
                    }
                }
                if let status {
                    Text(status.text)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(status.tint)
                        .lineLimit(1)
                }
            }
        }
        .contextMenu {
            Button("Connect", action: connect)
                .disabled(connection == .connecting)
        }
    }

    @ViewBuilder
    private var spinner: some View {
        if isSnapshot {
            Image(systemName: "circle.dotted")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.notchSecondary)
        } else {
            ProgressView().controlSize(.mini)
        }
    }
}

private struct ConnectButton: View {
    let title: String
    let symbol: String
    let compact: Bool
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if compact {
                    Image(systemName: symbol)
                        .font(.system(size: 8.5, weight: .bold))
                        .frame(width: 20)
                } else {
                    Text(title)
                        .font(.system(size: 9.5, weight: .semibold))
                        .padding(.horizontal, 7)
                }
            }
            .foregroundStyle(.white)
            .frame(height: 17)
            .background(Capsule().fill(Color.white.opacity(hovering ? 0.24 : 0.14)))
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}
