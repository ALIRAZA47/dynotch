import SwiftUI

/// The Control section's middle: the display's brightness and the sound's volume as thick sliders
/// like Control Center's, each with its name on the left and its level on the right, and where the
/// sound goes beside the volume. The brightness slider can be used when DisplayServices can set the
/// built-in display; otherwise it stays, dimmed, so the rows don't jump.
struct LevelControls: View {
    let metrics: ControlMetrics
    @ObservedObject private var volume = VolumeMonitor.shared
    @ObservedObject private var brightness = BrightnessMonitor.shared
    /// Snapshots have no display or output to read, so they show samples.
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        let level = brightness.level ?? (isSnapshot ? 0.68 : nil)
        let canSetBrightness = (brightness.canSetLevel || isSnapshot) && level != nil
        VStack(spacing: metrics.rowGap) {
            LevelSlider(title: "Display", value: Double(level ?? 0), isEnabled: canSetBrightness,
                        readout: canSetBrightness ? nil : "–", metrics: metrics,
                        symbol: { $0 < 0.5 ? "sun.min.fill" : "sun.max.fill" }) {
                brightness.set(Float($0))
            } accessory: {
                Color.clear
            }
            .help(canSetBrightness ? "" : "This display's brightness can't be set from here")
            LevelSlider(title: "Sound", value: volume.isMuted ? 0 : Double(volume.volume),
                        isEnabled: volume.canSetVolume || isSnapshot, readout: volume.isMuted || volume.volume <= 0 ? "Mute" : nil, metrics: metrics,
                        symbol: { volume.isMuted || $0 <= 0 ? "speaker.slash.fill"
                            : $0 < 0.34 ? "speaker.wave.1.fill" : $0 < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill" }) {
                volume.setVolume(Float($0))
            } accessory: {
                HStack(spacing: 6) {
                    if volume.canMute {
                        MuteButton(isMuted: volume.isMuted, size: metrics.slider, action: volume.toggleMute)
                    }
                    OutputMenu(height: metrics.slider)
                }
            }
        }
        .onAppear { brightness.refresh() }
    }
}

extension NotchTheme {
    /// A level slider's fill: white on the dark panel; the accent on the light one, or near-black
    /// for an accent too pale to stand out from the track.
    var levelFill: Color {
        if isDark { return primary }
        return Self.contrast(Self.luminance(of: accent), Self.luminance(of: hover)) >= 3 ? accent : primary
    }

    /// The symbol riding on a level slider's fill.
    var levelInk: Color {
        if isDark { return background }
        return Self.contrast(Self.luminance(of: accent), Self.luminance(of: hover)) >= 3 ? onAccent : background
    }
}

/// A thick slider like Control Center's: drag along it or click anywhere on it. A fully rounded
/// track, filled up to the level; the fill is the handle, never shorter than a circle, and its
/// symbol rides inside it at the left end.
private struct LevelSlider<Accessory: View>: View {
    let title: String
    let value: Double
    var isEnabled = true
    /// Said instead of the percentage, like "Mute".
    var readout: String?
    let metrics: ControlMetrics
    /// The symbol for a level, so it changes while dragging.
    let symbol: (Double) -> String
    let onChange: (Double) -> Void
    @ViewBuilder var accessory: Accessory
    @Environment(\.notchTheme) private var theme
    /// While dragging, the fill follows the pointer rather than the system's answer.
    @ViewState private var dragValue: Double?

    init(title: String, value: Double, isEnabled: Bool = true, readout: String? = nil, metrics: ControlMetrics,
         symbol: @escaping (Double) -> String, onChange: @escaping (Double) -> Void,
         @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.value = value
        self.isEnabled = isEnabled
        self.readout = readout
        self.metrics = metrics
        self.symbol = symbol
        self.onChange = onChange
        self.accessory = accessory()
    }

    private static var step: Double { 1.0 / 16 }

    /// What the slider is set to, or where the pointer has it while dragging.
    private var shown: Double { min(1, max(0, dragValue ?? value)) }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.primary)
                .lineLimit(1)
                .frame(width: metrics.labelWidth, alignment: .leading)
                .opacity(isEnabled ? 1 : 0.5)
            track
            // The level as a number, "68%". The slider says it as its value, so VoiceOver skips it.
            Text(dragValue == nil ? readout ?? percent(shown) : percent(shown))
                .font(NotchFont.time(12, .medium))
                .foregroundStyle(theme.secondary)
                .lineLimit(1)
                .frame(width: 38, alignment: .trailing)
                .opacity(isEnabled ? 1 : 0.5)
                .accessibilityHidden(true)
            accessory
                .frame(width: metrics.accessoryWidth, alignment: .trailing)
        }
        .frame(height: metrics.slider)
    }

    private func percent(_ level: Double) -> String { "\(Int((level * 100).rounded()))%" }

    private var track: some View {
        let shown = shown
        return GeometryReader { proxy in
            let height = proxy.size.height
            let travel = max(1, proxy.size.width - height)
            let shape = RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            ZStack(alignment: .leading) {
                shape.fill(theme.hover)
                shape.strokeBorder(theme.line, lineWidth: 1)
                shape.fill(theme.levelFill)
                    .frame(width: height + travel * shown)
                Image(systemName: symbol(shown))
                    .font(.system(size: height * 0.42, weight: .semibold))
                    .foregroundStyle(theme.levelInk)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: height, height: height)
            }
            .contentShape(shape)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    // The fill's right end follows the pointer, as Control Center's does.
                    let fraction = min(1, max(0, (drag.location.x - height / 2) / travel))
                    dragValue = fraction
                    onChange(fraction)
                }
                .onEnded { _ in dragValue = nil })
        }
        .opacity(isEnabled ? 1 : 0.4)
        .allowsHitTesting(isEnabled)
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityValue(readout ?? "\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            switch direction {
            case .increment: onChange(min(1, value + Self.step))
            case .decrement: onChange(max(0, value - Self.step))
            @unknown default: break
            }
        }
    }
}

/// Mutes the sound, beside the output. Solid accent while muted.
private struct MuteButton: View {
    let isMuted: Bool
    let size: CGFloat
    let action: () -> Void
    @Environment(\.notchTheme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isMuted ? theme.onAccent : theme.primary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
                .background(theme.controlShape.fill(isMuted ? theme.accent : hovering ? theme.controlHover : theme.hover))
                .contentShape(theme.controlShape)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.94))
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .help(isMuted ? "Unmute" : "Mute")
        .accessibilityLabel(isMuted ? "Unmute" : "Mute")
    }
}

/// Where the sound goes, on a button beside the volume, and a menu of the Mac's outputs to send it elsewhere.
private struct OutputMenu: View {
    var height: CGFloat = 28
    @ObservedObject private var outputs = AudioOutputs.shared
    @Environment(\.notchTheme) private var theme

    var body: some View {
        MenuButton(help: "Sound output") { hovering in
            HStack(spacing: 7) {
                Image(systemName: outputs.current?.symbol ?? "hifispeaker.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .frame(width: 16)
                Text(outputs.current?.name ?? "Output")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(theme.secondary)
            }
            .foregroundStyle(theme.primary)
            .padding(.horizontal, 9)
            .frame(height: height)
            .background(theme.controlShape.fill(hovering ? theme.controlHover : theme.hover))
            .animation(.notchHighlight, value: hovering)
        } items: {
            outputs.reload()
            return outputs.devices.map { device in
                .item(device.name, isChecked: device.id == outputs.currentID) { outputs.select(device) }
            }
        }
        .accessibilityValue(outputs.current?.name ?? "")
    }
}
