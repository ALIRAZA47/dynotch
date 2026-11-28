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
    static let macName = Host.current().localizedName ?? "This Mac"
    static let bluetoothMessage = "See your AirPods, keyboard and more."
    static let bluetoothButton = "Allow Bluetooth"

    /// `PermissionPrompt` without its symbol, for a card too short for it.
    private var bluetoothAsk: some View {
        VStack(spacing: 6) {
            Text(Self.bluetoothMessage)
                .font(NotchFont.footnote)
                .foregroundStyle(theme.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            PillButton(title: Self.bluetoothButton, action: monitor.requestAccess)
        }
        .frame(maxWidth: .infinity)
    }

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
                        // As much as the card has room for: the whole prompt, then the words and the
                        // button under the Mac, then those alone.
                        ViewThatFits(in: .vertical) {
                            VStack(alignment: .leading, spacing: 8) {
                                macRow(compact: compact)
                                PermissionPrompt(symbol: "dot.radiowaves.right", message: Self.bluetoothMessage,
                                                 buttonTitle: Self.bluetoothButton, action: monitor.requestAccess)
                            }
                            VStack(spacing: 8) {
                                macRow(compact: compact)
                                bluetoothAsk
                            }
                            bluetoothAsk
                        }
                    }
                }
                if showsSystem {
                    SystemFooter()
                }
            }
        }
        // The levels are polled only while a view showing them is on screen.
        .onAppear { monitor.addViewer() }
        .onDisappear { monitor.removeViewer() }
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
/// row's own quiet color; a failure is said in it too, as Orbit keeps red for a battery running out.
private struct Status {
    let text: String
    let tint: Color?

    init?(_ connection: DeviceBatteryMonitor.Connection?) {
        switch connection {
        case .connecting: (text, tint) = ("Connecting…", nil)
        case .disconnecting: (text, tint) = ("Disconnecting…", nil)
        case .failed(let message): (text, tint) = (message, nil)
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
        charging ? theme.live : level <= 20 ? theme.alert : theme.primary
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

/// Connect, or Retry: a wash of the accent with a label in the primary color, as short as the
/// row's first line, so the rows keep their height.
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
            .glass(.tint(theme.accent), in: theme.controlShape, isLit: hovering)
            .contentShape(theme.controlShape)
            .fixedSize()
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .help(title)
        .accessibilityLabel(title)
    }
}

// MARK: Control section

/// The Control section's foot: "Batteries" with the system's readings across from it, then a chip
/// for the Mac and each connected device with its level, and the paired devices that aren't
/// connected, each a tap from connecting. Low levels are red. More than fit scroll.
struct ControlBatteries: View {
    let metrics: ControlMetrics
    @ObservedObject private var power = PowerMonitor.shared
    @ObservedObject private var monitor = DeviceBatteryMonitor.shared
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.notchTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Batteries")
                    .font(NotchFont.label)
                    .foregroundStyle(theme.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                SystemLine()
            }
            .frame(height: 14)
            Scroller(.vertical, fadesOverflow: true) {
                FlowLayout(spacing: metrics.rowGap) {
                    chips
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { monitor.addViewer() }
        .onDisappear { monitor.removeViewer() }
    }

    @ViewBuilder
    private var chips: some View {
        if power.hasBattery {
            BatteryChip(symbol: "laptopcomputer", name: isSnapshot ? "MacBook Pro" : DevicesWidget.macName,
                        level: power.level, charging: power.isCharging || power.isPluggedIn,
                        detail: power.isCharging ? "Charging" : power.isPluggedIn ? "Plugged in" : nil, height: metrics.chip)
        }
        if monitor.isAuthorized {
            let connected = monitor.devices.filter { $0.lowest != nil || $0.batteryCase != nil }
            ForEach(connected) { device in
                connectedChip(device)
            }
            ForEach(monitor.paired) { device in
                PairedChip(device: device, connection: monitor.connections[device.id], height: metrics.chip) {
                    monitor.connect(device)
                }
            }
            if connected.isEmpty, monitor.paired.isEmpty {
                Text("No Bluetooth devices connected")
                    .font(NotchFont.footnote)
                    .foregroundStyle(theme.secondary)
                    .frame(height: metrics.chip)
            }
        } else {
            HStack(spacing: 10) {
                Text(DevicesWidget.bluetoothMessage)
                    .font(NotchFont.footnote)
                    .foregroundStyle(theme.secondary)
                    .lineLimit(1)
                PillButton(title: DevicesWidget.bluetoothButton, height: metrics.chip, action: monitor.requestAccess)
            }
            .frame(height: metrics.chip)
        }
    }

    private func connectedChip(_ device: DeviceBatteryMonitor.Device) -> some View {
        let parts = [device.left.map { "L \($0)%" }, device.right.map { "R \($0)%" }, device.batteryCase.map { "Case \($0)%" }]
            .compactMap { $0 }
        let status = Status(monitor.connections[device.id])
        return BatteryChip(symbol: device.kind.symbol, name: device.name, level: device.lowest ?? device.batteryCase ?? 0,
                           charging: false, detail: status?.text ?? (parts.isEmpty ? nil : parts.joined(separator: " · ")),
                           height: metrics.chip)
            .contextMenu {
                Button("Disconnect") { monitor.disconnect(device) }
                    .disabled(monitor.connections[device.id] == .disconnecting)
            }
    }
}

/// A device's symbol, its name, a small battery and the level, on a raised chip. Red at 20% and
/// under; a bolt in green while charging.
private struct BatteryChip: View {
    let symbol: String
    let name: String
    let level: Int
    let charging: Bool
    /// Said in the tooltip and to VoiceOver: an AirPods' buds and case, "Charging".
    let detail: String?
    let height: CGFloat
    @Environment(\.notchTheme) private var theme

    var body: some View {
        let isLow = level <= 20 && !charging
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.secondary)
                .frame(width: 16)
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.primary)
                .lineLimit(1)
                .frame(maxWidth: 150, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            BatteryGlyph(level: level, tint: isLow ? theme.alert : charging ? theme.live : theme.primary)
            if charging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(theme.live)
            }
            Text("\(level)%")
                .font(NotchFont.time(11.5, .medium))
                .foregroundStyle(isLow ? theme.alert : theme.primary)
        }
        .padding(.horizontal, 9)
        .frame(height: height)
        .background {
            theme.controlShape.fill(theme.raised)
            theme.controlShape.strokeBorder(theme.line, lineWidth: 1)
        }
        .help(detail.map { "\(name): \($0)" } ?? name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(["\(level) percent", detail].compactMap { $0 }.joined(separator: ", "))
    }
}

/// A battery drawn small: an outline, its nub, and the charge inside.
private struct BatteryGlyph: View {
    let level: Int
    let tint: Color
    @Environment(\.notchTheme) private var theme

    var body: some View {
        HStack(spacing: 1) {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .strokeBorder(theme.secondary, lineWidth: 1)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        RoundedRectangle(cornerRadius: 1.2, style: .continuous)
                            .fill(tint)
                            .frame(width: max(1.5, proxy.size.width * CGFloat(min(100, max(0, level))) / 100))
                    }
                    .padding(2)
                }
                .frame(width: 21, height: 10)
            RoundedRectangle(cornerRadius: 0.75)
                .fill(theme.secondary)
                .frame(width: 1.5, height: 4)
        }
        .accessibilityHidden(true)
    }
}

/// A paired device that isn't connected: its symbol and name, quiet, on an outline chip, and
/// Connect in the accent. The whole chip connects it; while connecting it says so.
private struct PairedChip: View {
    let device: DeviceBatteryMonitor.PairedDevice
    let connection: DeviceBatteryMonitor.Connection?
    let height: CGFloat
    let connect: () -> Void
    @Environment(\.notchTheme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        let status = Status(connection)
        let isConnecting = connection == .connecting
        Button(action: connect) {
            HStack(spacing: 6) {
                Image(systemName: device.kind.symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.tertiary)
                    .frame(width: 16)
                Text(device.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 150, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                if let status {
                    Text(status.text)
                        .font(NotchFont.caption)
                        .foregroundStyle(theme.secondary)
                        .lineLimit(1)
                }
                if !isConnecting {
                    Text(status == nil ? "Connect" : "Retry")
                        .font(NotchFont.label)
                        .foregroundStyle(theme.accentText)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: height)
            .background {
                if hovering { theme.controlShape.fill(theme.hover) }
                theme.controlShape.strokeBorder(theme.line, lineWidth: 1)
            }
            .contentShape(theme.controlShape)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.97))
        .disabled(isConnecting)
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .help(isConnecting ? "Connecting \(device.name)" : "Connect \(device.name)")
        .accessibilityLabel(device.name)
        .accessibilityValue(status?.text ?? "Not connected")
        .accessibilityHint("Connects it")
        .contextMenu {
            Button("Connect", action: connect)
                .disabled(isConnecting)
        }
    }
}
