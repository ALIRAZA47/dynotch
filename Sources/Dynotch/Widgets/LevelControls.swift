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
        GeometryReader { proxy in
            // In a short notch the names go and the sliders thin, which the symbols on them make up for.
            let compact = proxy.size.height < 164
            VStack(alignment: .leading, spacing: compact ? 8 : 10) {
                if brightness.canSetLevel || isSnapshot, let level = brightness.level ?? (isSnapshot ? 0.68 : nil) {
                    LevelSlider(title: "Display", symbol: level < 0.5 ? "sun.min.fill" : "sun.max.fill", value: Double(level),
                                compact: compact) {
                        brightness.set(Float($0))
                    }
                }
                LevelSlider(title: "Sound", symbol: volume.symbol, value: volume.isMuted ? 0 : Double(volume.volume),
                            isEnabled: volume.canSetVolume || isSnapshot, compact: compact) {
                    volume.setVolume(Float($0))
                } accessory: {
                    if volume.canMute {
                        CardButton(symbol: volume.isMuted ? "speaker.slash.fill" : "speaker.fill",
                                   help: volume.isMuted ? "Unmute" : "Mute", action: volume.toggleMute)
                    }
                }
                Spacer(minLength: 0)
                OutputMenu(height: compact ? 28 : 32)
            }
        }
        .onAppear { brightness.refresh() }
    }
}

/// A wide slider like Control Center's: drag along it or click anywhere on it. A channel pressed
/// into the glass, filled with white glass up to the level; its symbol sits on the fill, and the
/// level is printed beside its name. A compact one leaves its name out, prints the level inside
/// the channel and keeps its accessory beside it.
private struct LevelSlider<Accessory: View>: View {
    let title: String
    let symbol: String
    let value: Double
    var isEnabled = true
    var compact = false
    let onChange: (Double) -> Void
    @ViewBuilder var accessory: Accessory
    @Environment(\.notchTheme) private var theme
    /// While dragging, the fill follows the pointer rather than the system's answer.
    @ViewState private var dragValue: Double?

    init(title: String, symbol: String, value: Double, isEnabled: Bool = true, compact: Bool = false,
         onChange: @escaping (Double) -> Void, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.symbol = symbol
        self.value = value
        self.isEnabled = isEnabled
        self.compact = compact
        self.onChange = onChange
        self.accessory = accessory()
    }

    private static var step: Double { 1.0 / 16 }

    /// White glass, lit from above, like the pearl buttons.
    private static var fill: LinearGradient {
        LinearGradient(colors: [.white, Color(white: 0.8)], startPoint: .top, endPoint: .bottom)
    }

    /// What the slider is set to, or where the pointer has it while dragging.
    private var shown: Double { min(1, max(0, dragValue ?? value)) }

    var body: some View {
        if compact {
            HStack(spacing: 6) {
                slider
                    .frame(height: 30)
                accessory
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(NotchFont.label)
                        .foregroundStyle(theme.secondary)
                    Spacer(minLength: 0)
                    readout
                        .foregroundStyle(theme.secondary)
                    accessory
                }
                .frame(height: 16)
                .padding(.leading, 2)
                slider
                    .frame(height: 36)
            }
        }
    }

    /// The level as a number, "68%". The slider says it as its value, so VoiceOver skips it.
    private var readout: some View {
        Text("\(Int((shown * 100).rounded()))%")
            .font(NotchFont.numeric(11))
            .lineLimit(1)
            .fixedSize()
            .accessibilityHidden(true)
    }

    private var slider: some View {
        let shown = shown
        let shape = RoundedRectangle(cornerRadius: compact ? 10 : 12, style: .continuous)
        return GeometryReader { proxy in
            let filled = proxy.size.width * shown
            ZStack(alignment: .leading) {
                GlassSurface(depth: .well, shape: shape)
                Rectangle()
                    .fill(Self.fill)
                    .frame(width: filled)
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(filled > 30 ? Color.black.opacity(0.72) : theme.secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .padding(.leading, 12)
                if compact {
                    // Dark where the fill has reached it, secondary on the empty channel beyond.
                    let printed = readout
                        .padding(.trailing, 10)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .trailing)
                    printed
                        .foregroundStyle(theme.secondary)
                        .mask(alignment: .leading) {
                            HStack(spacing: 0) {
                                Color.clear.frame(width: filled)
                                Color.black
                            }
                        }
                    printed
                        .foregroundStyle(Color.black.opacity(0.6))
                        .mask(alignment: .leading) {
                            Color.black.frame(width: filled)
                        }
                }
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

/// Where the sound goes, on a piece of glass, and a menu of the Mac's outputs to send it elsewhere.
private struct OutputMenu: View {
    var height: CGFloat = 32
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
            .frame(height: height)
            .glass(.control, in: RoundedRectangle(cornerRadius: 10, style: .continuous), isLit: hovering)
            .animation(.notchHighlight, value: hovering)
        } items: {
            outputs.reload()
            return outputs.devices.map { device in
                .item(device.name, isChecked: device.id == outputs.currentID) { outputs.select(device) }
            }
        }
    }
}
