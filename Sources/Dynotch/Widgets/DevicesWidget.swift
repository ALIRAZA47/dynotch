import SwiftUI

/// The Mac's battery plus every connected Bluetooth device that reports one.
struct DevicesWidget: View {
    @ObservedObject private var power = PowerMonitor.shared
    @ObservedObject private var monitor = DeviceBatteryMonitor.shared

    var body: some View {
        WidgetCard(title: "Batteries", symbol: "battery.75percent") {
            VStack(alignment: .leading, spacing: 8) {
                if power.hasBattery {
                    DeviceRow(symbol: "laptopcomputer", name: Host.current().localizedName ?? "This Mac",
                              detail: power.isCharging ? "Charging" : power.isPluggedIn ? "Plugged in" : nil,
                              level: power.level, charging: power.isCharging || power.isPluggedIn)
                }
                if monitor.isAuthorized {
                    ForEach(monitor.devices.filter { $0.lowest != nil || $0.batteryCase != nil }.prefix(3)) { device in
                        DeviceRow(symbol: device.kind.symbol, name: device.name, detail: budsDetail(device),
                                  level: device.lowest ?? device.batteryCase ?? 0, charging: false)
                    }
                    if monitor.devices.isEmpty, !power.hasBattery {
                        Text("No Bluetooth devices connected")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.notchTertiary)
                    }
                } else {
                    Spacer(minLength: 0)
                    PillButton(title: "Show Bluetooth devices", symbol: "dot.radiowaves.right", action: monitor.requestAccess)
                        .frame(maxWidth: .infinity)
                    Spacer(minLength: 0)
                }
            }
        }
        .onAppear { Task { await monitor.refresh() } }
    }

    private func budsDetail(_ device: DeviceBatteryMonitor.Device) -> String? {
        let parts = [device.left.map { "L \($0)%" }, device.right.map { "R \($0)%" }, device.batteryCase.map { "Case \($0)%" }]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct DeviceRow: View {
    let symbol: String
    let name: String
    let detail: String?
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
                        .foregroundStyle(Color.notchTertiary)
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
