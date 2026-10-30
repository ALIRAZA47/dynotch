import SwiftUI

/// The Mac's battery plus every connected Bluetooth device that reports one, then the paired devices
/// that aren't connected, headphones first, each with a Connect button. More than fit scroll.
struct DevicesWidget: View {
    /// CPU, memory and network at the foot of the card, as on the Control tab.
    var showsSystem = false
    @ObservedObject private var power = PowerMonitor.shared
    @ObservedObject private var monitor = DeviceBatteryMonitor.shared
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.notchTheme) private var theme

    /// Looked up once: `Host` can be slow to answer.
    private static let macName = Host.current().localizedName ?? "This Mac"

    var body: some View {
        WidgetCard(title: "Batteries", symbol: "battery.75percent") {
            VStack(spacing: 8) {
                // In a narrow card each name gets a line of its own.
                GeometryReader { proxy in
                    let compact = proxy.size.width < 150
                    if monitor.isAuthorized {
                        Scroller(.vertical, fadesOverflow: true) {
                            rows(compact: compact)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            macRow(compact: compact)
                            PermissionPrompt(symbol: "dot.radiowaves.right", message: "See your AirPods, keyboard and more.",
                                             buttonTitle: "Allow Bluetooth", action: monitor.requestAccess)
                        }
                    }
                }
                if showsSystem {
                    SystemFooter()
                }
            }
        }
        .onAppear { Task { await monitor.refresh() } }
    }

    private func rows(compact: Bool) -> some View {
        let connected = monitor.devices.filter { $0.lowest != nil || $0.batteryCase != nil }
        return VStack(alignment: .leading, spacing: 6) {
            macRow(compact: compact)
            ForEach(connected) { device in
                connectedRow(device, compact: compact)
            }
            if connected.isEmpty, !power.hasBattery, monitor.paired.isEmpty {
                Text("No Bluetooth devices connected")
                    .font(NotchFont.footnote)
                    .foregroundStyle(theme.secondary)
            }
            ForEach(monitor.paired) { device in
                PairedRow(device: device, connection: monitor.connections[device.id], compact: compact, isSnapshot: isSnapshot) {
                    monitor.connect(device)
                }
            }
        }
    }

    @ViewBuilder
    private func macRow(compact: Bool) -> some View {
        if power.hasBattery {
            DeviceRow(symbol: "laptopcomputer", name: isSnapshot ? "MacBook Pro" : Self.macName,
                      detail: power.isCharging ? "Charging" : power.isPluggedIn ? "Plugged in" : nil,
                      level: power.level, charging: power.isCharging || power.isPluggedIn, compact: compact)
        }
    }

    private func connectedRow(_ device: DeviceBatteryMonitor.Device, compact: Bool) -> some View {
        let status = Status(monitor.connections[device.id])
        let buds = budsDetail(device)
        return DeviceRow(symbol: device.kind.symbol, name: device.name, detail: status?.text ?? buds,
                         detailTint: status?.tint, detailListsLevels: status == nil && buds != nil,
                         level: device.lowest ?? device.batteryCase ?? 0, charging: false, compact: compact)
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

/// What a row says while it connects or disconnects, or after that failed. No tint means the
/// row's own quiet color.
private struct Status {
    let text: String
    let tint: Color?

    init?(_ connection: DeviceBatteryMonitor.Connection?) {
        switch connection {
        case .connecting: (text, tint) = ("Connecting…", nil)
        case .disconnecting: (text, tint) = ("Disconnecting…", nil)
        case .failed(let message): (text, tint) = (message, Color.orange)
        case nil: return nil
        }
    }
}

/// A device's symbol in a ring that shows its level, its name with a line about it, and the level.
/// A compact row leaves the level to the ring and the line underneath.
private struct DeviceRow: View {
    let symbol: String
    let name: String
    let detail: String?
    var detailTint: Color?
    /// The line underneath already gives the levels, like an AirPods' buds and case.
    var detailListsLevels = false
    let level: Int
    let charging: Bool
    var compact = false
    @Environment(\.notchTheme) private var theme

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                ProgressRing(progress: Double(level) / 100, color: color, lineWidth: 2.6)
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.secondary)
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(NotchFont.body)
                    .foregroundStyle(theme.primary)
                    .lineLimit(1)
                    .help(name)
                if let detail {
                    Text(detail)
                        .font(NotchFont.caption)
                        .foregroundStyle(detailTint ?? theme.tertiary)
                        .lineLimit(1)
                } else if compact {
                    percentage
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !compact || (detail != nil && !detailListsLevels) {
                percentage
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var percentage: some View {
        HStack(spacing: 2) {
            if charging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 8))
            }
            Text("\(level)%")
                .font(NotchFont.numeric(compact ? 10.5 : 11.5))
        }
        .foregroundStyle(color)
        .layoutPriority(1)
    }

    private var color: Color {
        charging ? .green : level <= 10 ? .red : level <= 20 ? .orange : theme.primary
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
    @Environment(\.notchTheme) private var theme

    var body: some View {
        let status = Status(connection)
        HStack(spacing: 6) {
            Image(systemName: device.kind.symbol)
                .font(.system(size: 12))
                .frame(width: 18)
                .foregroundStyle(theme.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(device.name)
                        .font(NotchFont.body)
                        .foregroundStyle(theme.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(device.name)
                    if !compact { action(status) }
                }
                // A narrow row keeps the first line for the name, and the button goes underneath.
                if compact {
                    HStack(spacing: 4) {
                        statusText(status?.text ?? "Not connected", tint: status?.tint)
                        action(status)
                    }
                } else if let status {
                    statusText(status.text, tint: status.tint)
                }
            }
        }
        .contextMenu {
            Button("Connect", action: connect)
                .disabled(connection == .connecting)
        }
    }

    @ViewBuilder
    private func action(_ status: Status?) -> some View {
        if connection == .connecting {
            spinner
                .frame(width: 16, height: 16)
        } else {
            ConnectButton(title: status == nil ? "Connect" : "Retry",
                          symbol: status == nil ? "link" : "arrow.clockwise", compact: compact, action: connect)
        }
    }

    private func statusText(_ text: String, tint: Color?) -> some View {
        Text(text)
            .font(NotchFont.caption)
            .foregroundStyle(tint ?? theme.tertiary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var spinner: some View {
        if isSnapshot {
            Image(systemName: "circle.dotted")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.secondary)
        } else {
            ProgressView().controlSize(.mini)
        }
    }
}

/// Connect, or Retry: a pill button's glass with the accent's light in it and a white label, as
/// short as the row's first line, so the rows keep their height.
private struct ConnectButton: View {
    let title: String
    let symbol: String
    let compact: Bool
    let action: () -> Void
    @Environment(\.notchTheme) private var theme
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
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8)
                }
            }
            .foregroundStyle(theme.primary)
            .frame(height: 18)
            .glass(.tint(theme.accent), in: Capsule(), isLit: hovering)
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .help(title)
        .accessibilityLabel(title)
    }
}
