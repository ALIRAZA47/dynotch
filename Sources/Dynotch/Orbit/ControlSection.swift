import SwiftUI

/// The Control section, like Control Center: a row of toggle tiles, the display's brightness and
/// the sound's volume as thick sliders with the output beside them, a row of one-tap actions, and
/// the batteries with the system's readings at the foot. Everything grows with the notch's height.
struct ControlSection: View {
    var body: some View {
        GeometryReader { proxy in
            let metrics = ControlMetrics(size: proxy.size)
            VStack(alignment: .leading, spacing: 0) {
                ControlTileRow(metrics: metrics)
                LevelControls(metrics: metrics)
                    .padding(.top, metrics.gap)
                if metrics.showsActions {
                    ControlActionRow(metrics: metrics)
                        .padding(.top, metrics.gap)
                }
                if metrics.showsBatteries {
                    ControlBatteries(metrics: metrics)
                        .padding(.top, metrics.gap)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
        }
        .background(ControlHeader())
    }
}

/// How big each part of the section is at the room it has: tighter in a short notch, roomier and
/// with the actions stacked over their names in a tall one. Below the smallest open size Settings
/// allows, the batteries and then the actions give way to the tiles and sliders; the command field
/// still reaches every action.
struct ControlMetrics {
    let tile: CGFloat
    let disc: CGFloat
    let slider: CGFloat
    let action: CGFloat
    let chip: CGFloat
    /// Between the section's parts.
    let gap: CGFloat
    /// Between the two sliders, and between rows of chips.
    let rowGap: CGFloat
    /// The actions show their symbol over their name, as in the board, rather than beside it.
    let stacksActions: Bool
    let showsActions: Bool
    let showsBatteries: Bool
    /// The column left of each slider with its name.
    let labelWidth: CGFloat = 58
    /// The column right of each slider: the output on Sound's row, empty on Display's.
    let accessoryWidth: CGFloat

    init(size: CGSize) {
        switch size.height {
        case ..<110:
            (tile, disc, slider, action, chip, gap, rowGap) = (34, 22, 20, 28, 22, 6, 4)
            stacksActions = false
        case ..<220:
            (tile, disc, slider, action, chip, gap, rowGap) = (40, 26, 22, 28, 22, 6, 6)
            stacksActions = false
        case ..<320:
            (tile, disc, slider, action, chip, gap, rowGap) = (48, 28, 28, 34, 24, 8, 8)
            stacksActions = false
        default:
            (tile, disc, slider, action, chip, gap, rowGap) = (64, 36, 34, 64, 30, 14, 12)
            stacksActions = true
        }
        accessoryWidth = min(190, max(140, (size.width * 0.24).rounded()))
        // What the parts above need, and the batteries' heading and one row of chips.
        let levels = tile + gap + slider * 2 + rowGap
        showsActions = size.height >= levels + gap + action
        showsBatteries = showsActions && size.height >= levels + gap * 2 + action + 20 + chip
    }
}

/// The tiles' and the actions' shape: the button roundness setting, a little rounder, as on the board.
extension NotchTheme {
    var tileShape: RoundedRectangle { RoundedRectangle(cornerRadius: radius + 6, style: .continuous) }
}

/// The band's second line: the Mac's battery and whether it's charging, or on a Mac without one,
/// the processor and memory. A view of its own, so a reading changing redraws only this.
private struct ControlHeader: View {
    @ObservedObject private var power = PowerMonitor.shared
    @ObservedObject private var system = SystemMonitor.shared

    var body: some View {
        Color.clear
            .orbitHeader("Control", subtitle: subtitle)
            .accessibilityHidden(true)
    }

    private var subtitle: String {
        guard power.hasBattery else {
            return "CPU \(Int((system.cpu * 100).rounded()))% · Mem \(Int((system.memoryFraction * 100).rounded()))%"
        }
        let state: String
        if power.isCharging {
            state = "Charging"
        } else if power.isPluggedIn {
            state = "Plugged in"
        } else if let minutes = power.minutesRemaining, minutes > 0 {
            state = String(format: "%d:%02d left", minutes / 60, minutes % 60)
        } else {
            state = "On battery"
        }
        return "\(power.level)% · \(state)"
    }
}

// MARK: Actions

/// The one-tap actions: the color picker, a screenshot, an AirPlay speaker, and sleeping the display.
struct ControlActionRow: View {
    let metrics: ControlMetrics
    private let toggles = QuickToggles.shared

    var body: some View {
        HStack(spacing: 8) {
            ControlAction(symbol: "eyedropper", title: "Color Picker", help: "Pick a color and copy its hex",
                          metrics: metrics, action: toggles.pickColor)
            ControlAction(symbol: "camera.viewfinder", title: "Capture", help: "Take a screenshot",
                          metrics: metrics, action: toggles.takeScreenshot)
            AirPlayAction(metrics: metrics)
            ControlAction(symbol: "moon.zzz.fill", title: "Sleep Display", help: "Sleep the display",
                          metrics: metrics, action: toggles.sleepDisplay)
        }
        .frame(height: metrics.action)
    }
}

/// An action's face: a raised tile with its symbol and name, beside each other or stacked.
struct ControlActionLabel<Icon: View>: View {
    let title: String
    let metrics: ControlMetrics
    var hovering = false
    @ViewBuilder var icon: Icon
    @Environment(\.notchTheme) private var theme

    var body: some View {
        let layout = metrics.stacksActions
            ? AnyLayout(VStackLayout(spacing: 6))
            : AnyLayout(HStackLayout(spacing: 7))
        layout {
            icon
                .frame(width: 18, height: 18)
            Text(title)
                .font(.system(size: metrics.stacksActions ? 11 : 12, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .foregroundStyle(theme.primary)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            theme.tileShape.fill(hovering ? theme.hover : theme.raised)
            theme.tileShape.strokeBorder(theme.line, lineWidth: 1)
        }
        .contentShape(theme.tileShape)
        .animation(.notchHighlight, value: hovering)
    }
}

private struct ControlAction: View {
    let symbol: String
    let title: String
    let help: String
    let metrics: ControlMetrics
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            ControlActionLabel(title: title, metrics: metrics, hovering: hovering) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
            }
        }
        .buttonStyle(PressableButtonStyle(scale: 0.96))
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(title)
        .accessibilityHint(help)
    }
}
