import AppKit
import SwiftUI

// MARK: Palette

/// The app icon's colors: a deep indigo-to-navy body, a lavender glow and an orange-to-magenta accent,
/// plus the surfaces of the settings window in light and dark mode.
enum Palette {
    static let indigo = Color(red: 0.20, green: 0.22, blue: 0.48)
    static let navy = Color(red: 0.05, green: 0.05, blue: 0.12)
    static let lavender = Color(red: 0.55, green: 0.45, blue: 1.0)
    static let lilac = Color(red: 0.66, green: 0.58, blue: 1.0)
    static let orange = Color(red: 1.0, green: 0.58, blue: 0.30)
    static let magenta = Color(red: 0.93, green: 0.25, blue: 0.56)

    static let sunset = LinearGradient(colors: [orange, magenta], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Switches, sliders and selections: lavender, a few shades deeper in light mode so it holds up on white.
    static let accent = Color(light: NSColor(srgbRed: 0.40, green: 0.27, blue: 0.94, alpha: 1),
                              dark: NSColor(srgbRed: 0.64, green: 0.56, blue: 1.0, alpha: 1))
    private static let accentTop = Color(light: NSColor(srgbRed: 0.53, green: 0.42, blue: 1.0, alpha: 1),
                                         dark: NSColor(srgbRed: 0.72, green: 0.64, blue: 1.0, alpha: 1))
    static let accentGradient = LinearGradient(colors: [accentTop, accent], startPoint: .top, endPoint: .bottom)
    /// Behind white text: deep enough to read in both modes.
    static let buttonGradient = LinearGradient(colors: [Color(red: 0.50, green: 0.40, blue: 1.0), Color(red: 0.36, green: 0.24, blue: 0.88)],
                                               startPoint: .top, endPoint: .bottom)

    static let window = Color(light: NSColor(srgbRed: 0.965, green: 0.961, blue: 0.984, alpha: 1),
                              dark: NSColor(srgbRed: 0.055, green: 0.058, blue: 0.112, alpha: 1))
    static let sidebar = Color(light: NSColor(srgbRed: 0.925, green: 0.918, blue: 0.965, alpha: 1),
                               dark: NSColor(srgbRed: 0.082, green: 0.086, blue: 0.157, alpha: 1))
    static let card = Color(light: .white, dark: NSColor(srgbRed: 0.105, green: 0.109, blue: 0.192, alpha: 1))
    static let stroke = Color(light: NSColor(white: 0, alpha: 0.075), dark: NSColor(white: 1, alpha: 0.075))
    /// Quiet fills: unselected chips, symbols of settings that are off.
    static let wash = Color(light: NSColor(white: 0, alpha: 0.05), dark: NSColor(white: 1, alpha: 0.07))
    /// The empty part of a slider, a switch that's off.
    static let track = Color(light: NSColor(white: 0, alpha: 0.12), dark: NSColor(white: 1, alpha: 0.16))
}

extension Color {
    /// A color that follows the light or dark appearance it's drawn in.
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

// MARK: Layout

/// A titled group of settings.
struct SettingsSection<Content: View>: View {
    let title: String
    var trailing: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.9)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(title)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 4)
            content
            if let footer {
                Text(footer)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// A rounded panel on the page. A selected one is outlined in the accent color;
/// one that's on gets a hint of it.
struct CardBackground: View {
    enum Highlight {
        case none, on, selected
    }

    var highlight = Highlight.none
    var cornerRadius: CGFloat = 14
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let dark = colorScheme == .dark
        shape.fill(Palette.card)
            .overlay {
                switch highlight {
                case .none: EmptyView()
                case .on: shape.fill(Palette.accent.opacity(dark ? 0.07 : 0.035))
                case .selected: shape.fill(Palette.accent.opacity(dark ? 0.13 : 0.06))
                }
            }
            .overlay {
                switch highlight {
                case .none: shape.strokeBorder(Palette.stroke)
                case .on: shape.strokeBorder(Palette.accent.opacity(dark ? 0.3 : 0.22))
                case .selected: shape.strokeBorder(Palette.accent.opacity(0.65), lineWidth: 1.5)
                }
            }
            .shadow(color: .black.opacity(dark ? 0 : 0.05), radius: 6, y: 2)
    }
}

/// Rows of settings in one card. Put a `CardDivider` between rows.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CardBackground())
    }
}

struct CardDivider: View {
    var body: some View {
        Rectangle().fill(Palette.stroke).frame(height: 1).padding(.leading, 14)
    }
}

/// Lays its children out left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, in: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, in: bounds.width) {
            var x = bounds.minX
            for (index, size) in zip(row.indices, row.sizes) {
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var sizes: [CGSize] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, in width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            if !row.indices.isEmpty, row.width + spacing + size.width > width {
                rows.append(row)
                row = Row(y: row.y + row.height + spacing)
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            row.sizes.append(size)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

// MARK: Controls

/// The on/off pill inside switch tiles and rows.
struct SwitchMark: View {
    let isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule().fill(isOn ? AnyShapeStyle(Palette.accentGradient) : AnyShapeStyle(Palette.track))
            Circle()
                .fill(.white)
                .padding(2)
                .shadow(color: .black.opacity(0.22), radius: 1.5, y: 1)
        }
        .frame(width: 34, height: 20)
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: isOn)
        .accessibilityHidden(true)
    }
}

/// A rounded square holding a symbol, filled with its tint while the setting is on.
struct SymbolBadge: View {
    let symbol: String
    var tint: Color = Palette.accent
    var isActive = true
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(isActive ? Color.white : Color.secondary)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(isActive ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Palette.wash)))
            .accessibilityHidden(true)
    }
}

/// Shrinks a little while pressed and outlines itself under the pointer.
struct TileButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 14

    func makeBody(configuration: Configuration) -> some View {
        TileButtonBody(configuration: configuration, cornerRadius: cornerRadius)
    }
}

private struct TileButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let cornerRadius: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @ViewState private var hovering = false

    var body: some View {
        configuration.label
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Palette.accent.opacity(hovering && isEnabled ? 0.35 : 0), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// An on/off setting as a tile you can click anywhere on.
struct SwitchTile: View {
    let title: String
    let detail: String
    let symbol: String
    var tint: Color = Palette.accent
    /// What VoiceOver calls the tile, when the title leans on its section.
    var spokenTitle: String?
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button { isOn.toggle() } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    SymbolBadge(symbol: symbol, tint: tint, isActive: isOn && isEnabled)
                    Spacer(minLength: 8)
                    SwitchMark(isOn: isOn)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(13)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(CardBackground(highlight: isOn && isEnabled ? .on : .none))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(TileButtonStyle())
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityLabel(spokenTitle ?? title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityHint(detail)
        .accessibilityAddTraits(.isToggle)
    }
}

/// A tile that does something rather than holding a setting, drawn with a dashed outline.
struct ActionTile: View {
    let title: String
    let detail: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                SymbolBadge(symbol: symbol, tint: Palette.magenta)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(13)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Palette.track, style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(TileButtonStyle())
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }
}

/// An on/off setting as a row in a card.
struct SwitchRow: View {
    let title: String
    var detail: String?
    var symbol: String?
    var tint: Color = Palette.accent
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 12) {
                if let symbol {
                    SymbolBadge(symbol: symbol, tint: tint, isActive: isOn, size: 26)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                SwitchMark(isOn: isOn)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityHint(detail ?? "")
        .accessibilityAddTraits(.isToggle)
    }
}

/// One of several options, as a tile with a picture above its name.
struct ChoiceTile<Art: View>: View {
    let title: String
    var detail: String?
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder var art: Art

    var body: some View {
        Button(action: action) {
            VStack(spacing: 9) {
                art.frame(height: 34)
                VStack(spacing: 2) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.center)
            }
            .padding(.vertical, 15)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .background(CardBackground(highlight: isSelected ? .selected : .none))
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                        .padding(9)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(TileButtonStyle())
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isSelected)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// A compact option: a symbol and a name in a rounded chip.
struct ChoiceChip: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 15)
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Palette.accent : Color.primary.opacity(0.78))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background {
                let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
                shape.fill(isSelected ? AnyShapeStyle(Palette.accent.opacity(0.14)) : AnyShapeStyle(Palette.wash))
                    .overlay(shape.strokeBorder(Palette.accent.opacity(isSelected ? 0.55 : 0), lineWidth: 1.2))
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(TileButtonStyle(cornerRadius: 9))
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// A slider in the app's colors. The arrow keys and VoiceOver move it a step at a time.
struct TrackSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    /// The value as it's read out, like "0.15 seconds".
    let spokenValue: String
    @FocusState private var isFocused: Bool

    private let knob: CGFloat = 18

    var body: some View {
        GeometryReader { proxy in
            let travel = max(1, proxy.size.width - knob)
            let fraction = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track).frame(height: 5)
                Capsule().fill(Palette.accentGradient).frame(width: knob / 2 + travel * fraction, height: 5)
                Circle()
                    .fill(.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                    .overlay(Circle().strokeBorder(Palette.accent, lineWidth: isFocused ? 2.5 : 0))
                    .offset(x: travel * fraction)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let fraction = min(max((drag.location.x - knob / 2) / travel, 0), 1)
                set(range.lowerBound + Double(fraction) * (range.upperBound - range.lowerBound))
            })
        }
        .frame(height: 22)
        .focusable(interactions: .activate)
        .focused($isFocused)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            switch direction {
            case .left, .down: set(value - step)
            case .right, .up: set(value + step)
            @unknown default: break
            }
        }
        .accessibilityRepresentation {
            Slider(value: $value, in: range, step: step) { Text(title) }
                .accessibilityValue(spokenValue)
        }
    }

    private func set(_ newValue: Double) {
        let stepped = range.lowerBound + ((newValue - range.lowerBound) / step).rounded() * step
        let clamped = min(max(stepped, range.lowerBound), range.upperBound)
        if clamped != value { value = clamped }
    }
}

/// A number with minus and plus buttons, for durations and counts.
struct NumberDial: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    let unit: String
    var tint: Color = Palette.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(value)")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(value)))
                Text(unit)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                DialButton(symbol: "minus", isEnabled: value > range.lowerBound) { change(by: -step) }
                DialButton(symbol: "plus", isEnabled: value < range.upperBound) { change(by: step) }
            }
            .padding(.top, 4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground())
        .accessibilityRepresentation {
            Stepper(value: $value, in: range, step: step) { Text(title) }
                .accessibilityValue("\(value) \(unit)")
        }
    }

    private func change(by amount: Int) {
        withAnimation(.snappy) { value = min(max(value + amount, range.lowerBound), range.upperBound) }
    }
}

private struct DialButton: View {
    let symbol: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 30, height: 26)
                .background(Capsule().fill(Palette.wash))
                .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
    }
}

/// A capsule button for actions on a settings page.
struct CapsuleButton: View {
    enum Kind {
        case plain, prominent, destructive
        /// Light on dark, for the page header.
        case glass
    }

    let title: String
    var symbol: String?
    var kind: Kind = .plain
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .bold))
                }
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 13)
            .frame(height: 28)
            .background(Capsule().fill(background))
            .overlay(Capsule().strokeBorder(kind == .glass ? Color.white.opacity(0.18) : .clear))
            .brightness(hovering && isEnabled ? 0.04 : 0)
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle())
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
    }

    private var foreground: Color {
        switch kind {
        case .plain: .primary
        case .prominent, .glass: .white
        case .destructive: .red
        }
    }

    private var background: AnyShapeStyle {
        switch kind {
        case .plain: AnyShapeStyle(Palette.wash)
        case .prominent: AnyShapeStyle(Palette.buttonGradient)
        case .destructive: AnyShapeStyle(Color.red.opacity(0.12))
        case .glass: AnyShapeStyle(Color.white.opacity(hovering ? 0.2 : 0.13))
        }
    }
}

// MARK: Logo

/// The app icon drawn in SwiftUI, so it looks the same in a bare debug build as in the app.
/// Measurements follow scripts/make-icon.swift, on its 824-point icon body.
struct DynotchLogo: View {
    var size: CGFloat

    var body: some View {
        let unit = size / 824
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Palette.indigo, Palette.navy], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Palette.lavender.opacity(0.55), Palette.lavender.opacity(0)],
                           center: UnitPoint(x: 0.5, y: 224 / 824.0), startRadius: 0, endRadius: 430 * unit)
            NotchShape(topRadius: 34 * unit, bottomRadius: 92 * unit)
                .fill(.black)
                .frame(width: 648 * unit, height: 230 * unit)
                .offset(x: 88 * unit)
            RoundedRectangle(cornerRadius: 30 * unit, style: .continuous)
                .fill(Palette.sunset)
                .frame(width: 126 * unit, height: 126 * unit)
                .offset(x: 186 * unit, y: 52 * unit)
            HStack(alignment: .center, spacing: 16 * unit) {
                ForEach([70.0, 124, 92, 142], id: \.self) { height in
                    Capsule().fill(Palette.lilac).frame(width: 22 * unit, height: height * unit)
                }
            }
            .frame(height: 142 * unit)
            .offset(x: 502 * unit, y: 44 * unit)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 185 * unit, style: .continuous))
        .accessibilityHidden(true)
    }
}
