import AppKit
import SwiftUI

// MARK: Palette

/// The settings window and the welcome tour in Orbit's colors: one flat surface, light or dark with
/// macOS, raised cards with a hairline round them, and the app icon's colors for the odd badge.
enum Palette {
    static let indigo = Color(red: 0.20, green: 0.22, blue: 0.48)
    static let lavender = Color(red: 0.55, green: 0.45, blue: 1.0)
    static let lilac = Color(red: 0.66, green: 0.58, blue: 1.0)
    static let orange = Color(red: 1.0, green: 0.58, blue: 0.30)
    static let magenta = Color(red: 0.93, green: 0.25, blue: 0.56)

    static let sunset = LinearGradient(colors: [orange, magenta], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// The page: Orbit's panel color.
    static let window = Color(light: hex(0xF6F6F8), dark: hex(0x161618))
    /// The sidebar and the welcome tour's footer: Orbit's raised color.
    static let sidebar = Color(light: hex(0xFFFFFF), dark: hex(0x212124))
    /// A card: raised and flat.
    static let cardTop = Color(light: hex(0xFFFFFF), dark: hex(0x212124))
    static let cardBottom = cardTop
    /// Hairlines round cards and between rows.
    static let rimLit = Color(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.08))
    static let rimShade = rimLit
    static let stroke = rimLit
    /// Quiet fills: a button, an unselected chip, a hovered row.
    static let wash = Color(light: hex(0xEBEBEF), dark: hex(0x2A2A2E))
    /// A button under the pointer.
    static let washHover = Color(light: hex(0xE1E1E6), dark: hex(0x323237))
    /// The empty part of a slider, a switch that's off.
    static let track = Color(light: hex(0xDCDCE1), dark: hex(0x3A3A3F))
    /// The outline of a switch that's off: 3:1 on a card in either appearance.
    static let switchEdge = Color(light: hex(0x8E8E93), dark: hex(0x76767C))
    /// A field's fill.
    static let field = Color(light: hex(0xFFFFFF), dark: hex(0x0F0F11))
    /// The desk the model notch hangs over, in the header and the welcome tour.
    static let wall = Color(light: hex(0xD9DCE2), dark: hex(0x2B2D33))
    /// The menu bar along the top of the desk.
    static let menuBar = Color(light: NSColor(srgbRed: 0.965, green: 0.965, blue: 0.973, alpha: 0.78),
                               dark: NSColor(srgbRed: 0.118, green: 0.122, blue: 0.137, alpha: 0.72))

    static let cardGradient = LinearGradient(colors: [cardTop, cardBottom], startPoint: .top, endPoint: .bottom)
    static let rimGradient = LinearGradient(colors: [rimLit, rimLit], startPoint: .top, endPoint: .bottom)

    /// Second-level text: details, footers, readouts. Orbit's grey, a step firmer with Increase
    /// Contrast. Give it to the text itself: on macOS a `Text`'s `.secondary` ignores a second level
    /// set higher up.
    static let secondaryText = Color(nsColor: NSColor(name: nil) { appearance in
        let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                                .accessibilityHighContrastDarkAqua])
        switch match {
        case .darkAqua: return hex(0xA1A1A6)
        case .accessibilityHighContrastDarkAqua: return hex(0xC7C7CC)
        case .accessibilityHighContrastAqua: return hex(0x48484C)
        default: return hex(0x6E6E73)
        }
    })

    static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    /// A color that follows the light or dark appearance it's drawn in.
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

// MARK: Accent

extension NotchAccent {
    /// The accent a few shades deeper, for the light window, where the accent itself is too pale to
    /// read: white text on it, and it as text on the page, both pass 4.5:1.
    var windowDeep: (red: Double, green: Double, blue: Double) {
        switch self {
        case .cobalt: (0.12, 0.33, 0.84)
        case .lavender: (0.40, 0.27, 0.94)
        case .blue: (0.0, 0.40, 0.86)
        case .teal: (0.0, 0.47, 0.50)
        case .green: (0.08, 0.48, 0.20)
        case .yellow: (0.56, 0.40, 0.0)
        case .orange: (0.72, 0.30, 0.0)
        case .pink: (0.80, 0.16, 0.42)
        case .red: (0.80, 0.14, 0.14)
        case .graphite: (0.42, 0.42, 0.46)
        }
    }
}

/// The user's accent as the settings window and the welcome tour draw it. On the light page it's a
/// deeper shade, under white text and as text itself. On the dark page the solid face is the notch's
/// own accent, and text in the accent is lifted to read on the page. Their roots put it in the
/// environment, and every control here reads it from there.
struct WindowAccent {
    /// The accent as text, rings and marks on the page: 4.5:1 on it in either appearance.
    let color: Color
    /// The solid face: the selected sidebar row, a switch that's on, a slider's fill.
    let fill: Color
    /// Kept for callers from before Orbit; the same as `fill`, which is flat.
    var top: Color { fill }
    /// Text and symbols on `fill`.
    let onFill: Color

    init(choice: NotchAccent) {
        self = Self.shades[choice] ?? Self(mixing: choice)
    }

    /// The solid face as a fill. Orbit has no gradients; kept so older callers draw it flat.
    var gradient: LinearGradient {
        LinearGradient(colors: [fill, fill], startPoint: .top, endPoint: .bottom)
    }

    /// Every accent's shades, worked out once, so nothing mixes colors while it draws.
    private static let shades = Dictionary(uniqueKeysWithValues: NotchAccent.allCases.map { ($0, Self(mixing: $0)) })

    private init(mixing choice: NotchAccent) {
        let dark = NotchTheme(accent: choice, isDark: true)
        let deep = NSColor(srgbRed: choice.windowDeep.red, green: choice.windowDeep.green, blue: choice.windowDeep.blue, alpha: 1)
        color = Color(light: deep, dark: NSColor(dark.accentText))
        fill = Color(light: deep, dark: NSColor(choice.color))
        onFill = Color(light: .white, dark: NSColor(dark.onAccent))
    }
}

private struct WindowAccentKey: EnvironmentKey {
    static let defaultValue = WindowAccent(choice: .cobalt)
}

extension EnvironmentValues {
    /// The accent the window controls draw in. Settings and the welcome tour put the user's in at
    /// their roots; anywhere else it's cobalt.
    var windowAccent: WindowAccent {
        get { self[WindowAccentKey.self] }
        set { self[WindowAccentKey.self] = newValue }
    }
}

extension View {
    /// Draws the window controls inside in `accent`.
    func windowAccent(_ accent: WindowAccent) -> some View {
        environment(\.windowAccent, accent)
    }

    /// The settings window's and the welcome tour's look: the user's accent, and an Orbit theme,
    /// light or dark with the window, at the user's button roundness, for the controls that read it.
    func orbitWindow(_ settings: AppSettings) -> some View {
        modifier(OrbitWindowModifier(settings: settings))
    }
}

private struct OrbitWindowModifier: ViewModifier {
    @ObservedObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        var theme = NotchTheme(accent: settings.notchAccent, isDark: colorScheme == .dark, radius: settings.buttonRadius)
        theme.isHighContrast = contrast == .increased
        return content
            .environment(\.notchTheme, theme)
            .windowAccent(WindowAccent(choice: settings.notchAccent))
    }
}

// MARK: Layout

/// A titled group of settings, headed in sentence case like System Settings.
struct SettingsSection<Content: View>: View {
    let title: String
    var trailing: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .accessibilityLabel(title)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.secondaryText)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 4)
            content
            if let footer {
                Text(footer)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// A raised card on the page with a hairline round it, as Orbit draws its cards. One that's on is
/// the same; a selected one is ringed with the accent.
struct CardBackground: View {
    enum Highlight {
        case none, on, selected
    }

    var highlight = Highlight.none
    var cornerRadius: CGFloat = 10
    @Environment(\.windowAccent) private var accent

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape.fill(Palette.cardTop)
            .overlay {
                switch highlight {
                case .none, .on: shape.strokeBorder(Palette.stroke)
                case .selected: shape.strokeBorder(accent.color, lineWidth: 2)
                }
            }
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

/// The hairline between rows in a card, edge to edge.
struct CardDivider: View {
    var body: some View {
        Rectangle().fill(Palette.stroke).frame(height: 1)
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

/// The on/off switch inside switch tiles and rows: a track at the button roundness that fills with
/// the accent, and a white knob riding in it.
struct SwitchMark: View {
    let isOn: Bool
    @Environment(\.windowAccent) private var accent
    @Environment(\.notchTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let radius = min(theme.radius + 2, 10)
        ZStack(alignment: isOn ? .trailing : .leading) {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(isOn ? accent.fill : Palette.track)
                // An outline at 3:1 while it's off, so the switch shows on the card.
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(isOn ? .clear : Palette.switchEdge))
            RoundedRectangle(cornerRadius: max(radius - 2, 1), style: .continuous)
                .fill(.white)
                .padding(2)
                .frame(width: 20)
                .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
        }
        .frame(width: 34, height: 20)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.2), value: isOn)
        .accessibilityHidden(true)
    }
}

/// A small rounded square holding a white symbol, filled with its color, like the badges in System
/// Settings' sidebar. Grey while its setting is off.
struct SymbolBadge: View {
    let symbol: String
    /// Without one, the window accent, with its symbol in the accent's onFill. Pass nil rather than
    /// the accent's color.
    var tint: Color?
    var isActive = true
    var size: CGFloat = 30

    @Environment(\.windowAccent) private var accent

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(isActive ? glyph : Palette.secondaryText)
            .frame(width: size, height: size)
            .background(shape.fill(isActive ? (tint ?? accent.fill) : Palette.wash))
            .accessibilityHidden(true)
    }

    /// White, except on the window accent, where it's the accent's own ink.
    private var glyph: Color {
        tint == nil ? accent.onFill : .white
    }
}

/// Shrinks a little while pressed and outlines itself under the pointer.
struct TileButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 10

    func makeBody(configuration: Configuration) -> some View {
        TileButtonBody(configuration: configuration, cornerRadius: cornerRadius)
    }
}

private struct TileButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let cornerRadius: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.windowAccent) private var accent
    @ViewState private var hovering = false

    var body: some View {
        configuration.label
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(accent.color.opacity(hovering && isEnabled ? 0.45 : 0), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
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
    /// The badge's color while it's on. Without one, the window accent.
    var tint: Color?
    /// What VoiceOver calls the tile, when the title leans on its section.
    var spokenTitle: String?
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button { isOn.toggle() } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    SymbolBadge(symbol: symbol, tint: tint, isActive: isOn && isEnabled, size: 26)
                    Spacer(minLength: 8)
                    SwitchMark(isOn: isOn)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(CardBackground(highlight: isOn && isEnabled ? .on : .none))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                SymbolBadge(symbol: symbol, tint: Palette.magenta, size: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Palette.track, style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
    /// The badge's color while it's on. Without one, the window accent.
    var tint: Color?
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 12) {
                if let symbol {
                    SymbolBadge(symbol: symbol, tint: tint, isActive: isOn, size: 24)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                SwitchMark(isOn: isOn)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityHint(detail ?? "")
        .accessibilityAddTraits(.isToggle)
    }
}

/// A row in a card with a name and a hint on the left and a control on the right, as Orbit's
/// settings rows are laid out.
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 48)
    }
}

/// One of several options, as a tile with a picture above its name.
struct ChoiceTile<Art: View>: View {
    let title: String
    var detail: String?
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder var art: Art
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(spacing: 9) {
                art.frame(height: 34)
                VStack(spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.secondaryText)
                    }
                }
                .multilineTextAlignment(.center)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .background(CardBackground(highlight: isSelected ? .selected : .none))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(TileButtonStyle())
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.2), value: isSelected)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// A compact option: a symbol and a name in a chip at the button roundness. The selected one is a
/// solid face of the accent.
struct ChoiceChip: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.windowAccent) private var accent
    @Environment(\.notchTheme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        let shape = theme.controlShape
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
            .foregroundStyle(isSelected ? accent.onFill : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(shape.fill(isSelected ? accent.fill : hovering ? Palette.washHover : Palette.wash))
            .contentShape(shape)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.97))
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Orbit's segmented control for a settings row: a track a shade off the card with the picked one
/// raised on it.
struct SettingSegments<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(value: Value, title: String)]

    var body: some View {
        CardSegments(selection: $selection, segments: options.map { .init(value: $0.value, title: $0.title) })
            .fixedSize()
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)
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
    @Environment(\.windowAccent) private var accent

    private let knob: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            let travel = max(1, proxy.size.width - knob)
            let fraction = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            // A thin track filled with the accent, and a white knob to drag.
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Palette.track).frame(height: 4)
                RoundedRectangle(cornerRadius: 2)
                    .fill(accent.fill)
                    .frame(width: knob / 2 + travel * fraction, height: 4)
                Circle()
                    .fill(.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
                    .overlay(Circle().strokeBorder(accent.color, lineWidth: isFocused ? 2.5 : 0))
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

/// How far along something is, like an update's download: a thin track that fills with the accent.
struct MeterBar: View {
    /// From 0 to 1.
    let value: Double
    @Environment(\.windowAccent) private var accent

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Palette.track)
                RoundedRectangle(cornerRadius: 2)
                    .fill(accent.fill)
                    .frame(width: proxy.size.width * max(0, min(1, value)))
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.2), value: value)
        .accessibilityRepresentation {
            ProgressView(value: max(0, min(1, value)))
        }
    }
}

/// A number with minus and plus buttons, for durations and counts.
struct NumberDial: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    let unit: String
    /// The dot beside the title. Without one, the window accent.
    var tint: Color?
    @Environment(\.windowAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(tint ?? accent.fill).frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(value)")
                    .font(.system(size: 28, weight: .medium, design: .monospaced))
                    .contentTransition(.numericText(value: Double(value)))
                Text(unit)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.secondaryText)
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
    @Environment(\.notchTheme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 30, height: 26)
                .background(theme.controlShape.fill(Palette.wash))
                .contentShape(theme.controlShape)
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
    }
}

/// A button for actions on a settings page, in Orbit's shapes. Plain is a fill a shade off the card;
/// prominent is a focus button, with spaced capitals and a block of the accent down its right edge;
/// destructive is a red focus button.
struct CapsuleButton: View {
    enum Kind {
        case plain, prominent, destructive
        /// Kept for callers from before Orbit: a quiet button with no fill until the pointer's on it.
        case glass
    }

    let title: String
    var symbol: String?
    var kind: Kind = .plain
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.notchTheme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            switch look {
            case .prominent:
                FocusButtonLabel(title: title, symbol: symbol, height: 28, hovering: hovering && isEnabled)
            case .destructive:
                FocusButtonLabel(title: title, symbol: symbol, tint: theme.alert, height: 28, hovering: hovering && isEnabled)
            case .plain, .glass:
                HStack(spacing: 6) {
                    if let symbol {
                        Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                    }
                    Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                }
                .foregroundStyle(look == .glass && !hovering ? Palette.secondaryText : Color.primary)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background {
                    if look == .plain || hovering {
                        theme.controlShape.fill(hovering && isEnabled ? Palette.washHover : Palette.wash)
                    }
                }
                .contentShape(theme.controlShape)
            }
        }
        .buttonStyle(PressableButtonStyle(scale: 0.96))
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(title)
    }

    /// A prominent button that's disabled looks plain, the way macOS greys out a default button.
    private var look: Kind { kind == .prominent && !isEnabled ? .plain : kind }
}
