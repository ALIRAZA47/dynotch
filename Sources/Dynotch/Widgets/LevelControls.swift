import SwiftUI

/// The Control tab's middle: the display's brightness and the sound's volume as wide sliders, and
/// where the sound goes. The brightness slider is there when DisplayServices can set the built-in display.
struct LevelControls: View {
    @ObservedObject private var volume = VolumeMonitor.shared
    @ObservedObject private var brightness = BrightnessMonitor.shared
    @Environment(\.notchTheme) private var theme
    /// Snapshots have no display or output to read, so they show samples.
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if brightness.canSetLevel || isSnapshot, let level = brightness.level ?? (isSnapshot ? 0.68 : nil) {
                LevelSlider(title: "Display", symbol: level < 0.5 ? "sun.min.fill" : "sun.max.fill", value: Double(level)) {
                    brightness.set(Float($0))
                }
            }
            LevelSlider(title: "Sound", symbol: volume.symbol, value: volume.isMuted ? 0 : Double(volume.volume),
                        isEnabled: volume.canSetVolume || isSnapshot) {
                volume.setVolume(Float($0))
            } accessory: {
                if volume.canMute {
                    CardButton(symbol: volume.isMuted ? "speaker.slash.fill" : "speaker.fill",
                               help: volume.isMuted ? "Unmute" : "Mute", action: volume.toggleMute)
                }
            }
            Spacer(minLength: 0)
            OutputMenu()
        }
        .onAppear { brightness.refresh() }
    }
}

/// A wide slider like Control Center's: drag along it or click anywhere on it. Its symbol sits on the fill.
private struct LevelSlider<Accessory: View>: View {
    let title: String
    let symbol: String
    let value: Double
    var isEnabled = true
    let onChange: (Double) -> Void
    @ViewBuilder var accessory: Accessory
    @Environment(\.notchTheme) private var theme
    /// While dragging, the fill follows the pointer rather than the system's answer.
    @ViewState private var dragValue: Double?

    init(title: String, symbol: String, value: Double, isEnabled: Bool = true, onChange: @escaping (Double) -> Void,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.symbol = symbol
        self.value = value
        self.isEnabled = isEnabled
        self.onChange = onChange
        self.accessory = accessory()
    }

    private static var step: Double { 1.0 / 16 }

    var body: some View {
        let shown = min(1, max(0, dragValue ?? value))
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title)
                    .font(NotchFont.label)
                    .foregroundStyle(theme.tertiary)
                Spacer(minLength: 0)
                accessory
            }
            .frame(height: 16)
            .padding(.leading, 2)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    shape.fill(theme.control)
                    Rectangle()
                        .fill(Color.white.opacity(0.94))
                        .frame(width: proxy.size.width * shown)
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(shown * proxy.size.width > 30 ? Color.black.opacity(0.72) : theme.secondary)
                        .contentTransition(.symbolEffect(.replace))
                        .padding(.leading, 12)
                }
                .clipShape(shape)
                .contentShape(shape)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let fraction = min(1, max(0, drag.location.x / max(1, proxy.size.width)))
                        dragValue = fraction
                        onChange(fraction)
                    }
                    .onEnded { _ in dragValue = nil })
            }
            .frame(height: 36)
            .opacity(isEnabled ? 1 : 0.4)
            .allowsHitTesting(isEnabled)
            .accessibilityElement()
            .accessibilityLabel(title)
            .accessibilityValue("\(Int((value * 100).rounded())) percent")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onChange(min(1, value + Self.step))
                case .decrement: onChange(max(0, value - Self.step))
                @unknown default: break
                }
            }
        }
    }
}

/// Where the sound goes, and a menu of the Mac's outputs to send it elsewhere.
private struct OutputMenu: View {
    @ObservedObject private var outputs = AudioOutputs.shared
    @Environment(\.notchTheme) private var theme

    var body: some View {
        MenuButton(help: "Sound output") { hovering in
            HStack(spacing: 8) {
                Image(systemName: outputs.current?.symbol ?? "hifispeaker.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16)
                Text(outputs.current?.name ?? "Output")
                    .font(NotchFont.body)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.tertiary)
            }
            .foregroundStyle(theme.primary)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? theme.controlHover : theme.control))
        } items: {
            outputs.reload()
            return outputs.devices.map { device in
                .item(device.name, isChecked: device.id == outputs.currentID) { outputs.select(device) }
            }
        }
    }
}
