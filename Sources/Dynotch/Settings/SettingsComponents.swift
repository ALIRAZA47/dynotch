import AppKit
import SwiftUI

// MARK: Palette

/// The app icon's colors: a deep indigo-to-navy body, a lavender glow and an orange-to-magenta accent,
/// plus the surfaces of the settings window in light and dark mode, and the sky of its header.
enum Palette {
    static let indigo = Color(red: 0.20, green: 0.22, blue: 0.48)
    static let navy = Color(red: 0.05, green: 0.05, blue: 0.12)
    static let lavender = Color(red: 0.55, green: 0.45, blue: 1.0)
    static let lilac = Color(red: 0.66, green: 0.58, blue: 1.0)
    static let orange = Color(red: 1.0, green: 0.58, blue: 0.30)
    static let magenta = Color(red: 0.93, green: 0.25, blue: 0.56)

    static let sunset = LinearGradient(colors: [orange, magenta], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Switches, sliders and selections: lavender, a few shades deeper in light mode so it holds up on white.
    @available(*, deprecated, message: "Read @Environment(\\.windowAccent), the user's accent in the window's shades")
    static let accent = Color(light: NSColor(srgbRed: 0.40, green: 0.27, blue: 0.94, alpha: 1),
                              dark: NSColor(srgbRed: 0.64, green: 0.56, blue: 1.0, alpha: 1))
    private static let accentTop = Color(light: NSColor(srgbRed: 0.53, green: 0.42, blue: 1.0, alpha: 1),
                                         dark: NSColor(srgbRed: 0.72, green: 0.64, blue: 1.0, alpha: 1))
    @available(*, deprecated, message: "Use the window accent's gradient, @Environment(\\.windowAccent).gradient")
    static let accentGradient = LinearGradient(colors: [accentTop, accent], startPoint: .top, endPoint: .bottom)
    /// Behind white text: deep enough to read in both modes.
    @available(*, deprecated, message: "Use the window accent's gradient under its onFill, like CapsuleButton(kind: .prominent)")
    static let buttonGradient = LinearGradient(colors: [Color(red: 0.50, green: 0.40, blue: 1.0), Color(red: 0.36, green: 0.24, blue: 0.88)],
                                               startPoint: .top, endPoint: .bottom)

    /// A neutral graphite in dark mode and a cool paper white in light mode, so the accent and the
    /// glass carry the color.
    static let window = Color(light: NSColor(srgbRed: 0.949, green: 0.949, blue: 0.961, alpha: 1),
                              dark: NSColor(srgbRed: 0.071, green: 0.073, blue: 0.086, alpha: 1))
    /// Under the sidebar's translucent material, and the welcome tour's footer.
    static let sidebar = Color(light: NSColor(srgbRed: 0.918, green: 0.918, blue: 0.937, alpha: 1),
                               dark: NSColor(srgbRed: 0.098, green: 0.1, blue: 0.118, alpha: 1))
    @available(*, deprecated, message: "Cards are glass now: use cardGradient, or CardBackground")
    static let card = Color(light: .white, dark: NSColor(srgbRed: 0.105, green: 0.109, blue: 0.192, alpha: 1))
    /// A card's glass, top to bottom: lit from above, falling off toward its foot.
    static let cardTop = Color(light: NSColor(white: 1, alpha: 0.96), dark: NSColor(white: 1, alpha: 0.075))
    static let cardBottom = Color(light: NSColor(white: 1, alpha: 0.78), dark: NSColor(white: 1, alpha: 0.035))
    /// A card's rim: bright along its top edge in dark mode; in light mode, white glass shows its
    /// edge where it turns away from the light, along the bottom.
    static let rimLit = Color(light: NSColor(white: 1, alpha: 1), dark: NSColor(white: 1, alpha: 0.2))
    static let rimShade = Color(light: NSColor(white: 0, alpha: 0.11), dark: NSColor(white: 1, alpha: 0.06))
    static let stroke = Color(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.08))
    /// Quiet fills: unselected chips, symbols of settings that are off.
    static let wash = Color(light: NSColor(white: 0, alpha: 0.05), dark: NSColor(white: 1, alpha: 0.07))
    /// The empty part of a slider, a switch that's off.
    static let track = Color(light: NSColor(white: 0, alpha: 0.11), dark: NSColor(white: 1, alpha: 0.14))

    static let cardGradient = LinearGradient(colors: [cardTop, cardBottom], startPoint: .top, endPoint: .bottom)
    static let rimGradient = LinearGradient(stops: [.init(color: rimLit, location: 0), .init(color: rimShade, location: 0.5),
                                                    .init(color: rimShade, location: 1)],
                                            startPoint: .top, endPoint: .bottom)

    // MARK: Stage

    /// The sky of the header above every page and the welcome tour, top to bottom. It's light or dark
    /// with the page under it.
    static let stageTop = Color(light: NSColor(srgbRed: 0.925, green: 0.925, blue: 0.941, alpha: 1),
                                dark: NSColor(srgbRed: 0.115, green: 0.118, blue: 0.137, alpha: 1))
    static let stageBottom = Color(light: NSColor(srgbRed: 0.957, green: 0.957, blue: 0.967, alpha: 1),
                                   dark: NSColor(srgbRed: 0.05, green: 0.052, blue: 0.062, alpha: 1))
    static let stageGradient = LinearGradient(colors: [stageTop, stageBottom], startPoint: .top, endPoint: .bottom)
    /// The window accent's light on the stage: a radial gradient from the top center, where the model
    /// notch hangs, this strong at its center, reaching `stageBloomRadius` and stretched
    /// `stageBloomStretch` times as wide.
    static func stageBloomOpacity(_ colorScheme: ColorScheme) -> Double { colorScheme == .dark ? 0.22 : 0.16 }
    static let stageBloomRadius: CGFloat = 230
    static let stageBloomStretch: CGFloat = 1.5
    /// A white glow under the stage's top edge, drawn like the bloom. The light stage has none.
    static let stageGlow = Color(light: NSColor(white: 1, alpha: 0), dark: NSColor(white: 1, alpha: 0.15))
    static let stageGlowRadius: CGFloat = 190
    static let stageGlowStretch: CGFloat = 1.9
    private static let stageFootEdge = Color(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0))
    private static let stageFootMiddle = Color(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.18))
    /// The 1 pt line along the stage's foot, where it meets the page: a hairline on the light stage,
    /// and on the dark one a line of light that fades out to both sides.
    static let stageFoot = LinearGradient(colors: [stageFootEdge, stageFootMiddle, stageFootEdge],
                                          startPoint: .leading, endPoint: .trailing)
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

/// The user's accent as the settings window and the welcome tour draw it: a deeper shade under white
/// text on the light page, and the notch's own color under dark ink on the dark one. Their roots put
/// it in the environment, and every control here reads it from there.
struct WindowAccent {
    /// Switch grooves, slider fills, prominent buttons, selected rims and accent text on the page.
    let color: Color
    /// The top of a fill, as if lit from above: `color` with 18% white in dark mode, and 6% in light
    /// mode, where more would take the white text on a prominent button under 4.5:1.
    let top: Color
    /// Text and symbols on a fill of the accent.
    let onFill: Color

    init(choice: NotchAccent) {
        self = Self.shades[choice] ?? Self(mixing: choice)
    }

    /// A fill of the accent, from `top` down to `color`.
    var gradient: LinearGradient {
        LinearGradient(colors: [top, color], startPoint: .top, endPoint: .bottom)
    }

    /// Every accent's shades, worked out once, so nothing mixes colors while it draws.
    private static let shades = Dictionary(uniqueKeysWithValues: NotchAccent.allCases.map { ($0, Self(mixing: $0)) })

    private init(mixing choice: NotchAccent) {
        let own = choice.color.resolve(in: EnvironmentValues())
        let light = choice.windowDeep
        let dark = (red: Double(own.red), green: Double(own.green), blue: Double(own.blue))
        color = Color(light: Self.srgb(light), dark: Self.srgb(dark))
        top = Color(light: Self.srgb(light, white: 0.06), dark: Self.srgb(dark, white: 0.18))
        onFill = Color(light: .white, dark: NSColor(NotchTheme.standard.onAccent))
    }

    /// An sRGB color with `white` of white mixed in.
    private static func srgb(_ color: (red: Double, green: Double, blue: Double), white: Double = 0) -> NSColor {
        func mix(_ part: Double) -> CGFloat { part + (1 - part) * white }
        return NSColor(srgbRed: mix(color.red), green: mix(color.green), blue: mix(color.blue), alpha: 1)
    }
}

private struct WindowAccentKey: EnvironmentKey {
    static let defaultValue = WindowAccent(choice: .lavender)
}

extension EnvironmentValues {
    /// The accent the window controls draw in. Settings and the welcome tour put the user's in at
    /// their roots; anywhere else it's lavender.
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
}

// MARK: Layout

/// A titled group of settings, headed in sentence case like System Settings.
struct SettingsSection<Content: View>: View {
    let title: String
    var trailing: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.primary)
                    .accessibilityLabel(title)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 12, weight: .medium))
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

/// A pane of glass on the page, lit from above like the cards in the notch. One that's on holds a
/// little of the accent's light; a selected one is ringed with it.
struct CardBackground: View {
    enum Highlight {
        case none, on, selected
    }

    var highlight = Highlight.none
    var cornerRadius: CGFloat = 14
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.windowAccent) private var accent

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let dark = colorScheme == .dark
        shape.fill(Palette.cardGradient)
            .overlay {
                switch highlight {
                case .none: EmptyView()
                case .on: shape.fill(LinearGradient(colors: [accent.color.opacity(dark ? 0.1 : 0.05), .clear],
                                                    startPoint: .top, endPoint: .bottom))
                case .selected: shape.fill(accent.color.opacity(dark ? 0.13 : 0.07))
                }
            }
            .overlay {
                switch highlight {
                case .none, .on: shape.strokeBorder(Palette.rimGradient)
                case .selected: shape.strokeBorder(accent.color.opacity(0.75), lineWidth: 1.5)
                }
            }
            .shadow(color: .black.opacity(dark ? 0.3 : 0.07), radius: dark ? 8 : 10, y: dark ? 3 : 4)
            .shadow(color: accent.color.opacity(highlight == .selected ? (dark ? 0.35 : 0.22) : 0), radius: 10)
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

/// The on/off pill inside switch tiles and rows: a groove that fills with the accent's light,
/// and a pearl of white glass riding in it.
struct SwitchMark: View {
    let isOn: Bool
    @Environment(\.windowAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? AnyShapeStyle(accent.gradient) : AnyShapeStyle(Palette.track))
                .overlay(Capsule().strokeBorder(LinearGradient(colors: [.black.opacity(0.12), .white.opacity(isOn ? 0.3 : 0.1)],
                                                               startPoint: .top, endPoint: .bottom)))
                .shadow(color: accent.color.opacity(isOn ? 0.45 : 0), radius: 5)
            Circle()
                .fill(LinearGradient(colors: [.white, Color(white: 0.9)], startPoint: .top, endPoint: .bottom))
                .padding(2)
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
        }
        .frame(width: 34, height: 20)
        // The pearl overshoots a little as it lands, unless motion is reduced.
        .animation(.notchLift(reduceMotion: reduceMotion), value: isOn)
        .accessibilityHidden(true)
    }
}

/// A rounded square holding a symbol: while the setting is on, a tile of glass filled with its tint,
/// lit along the top like an app icon.
struct SymbolBadge: View {
    let symbol: String
    /// Without one, the window accent, with its symbol in the accent's onFill. Pass nil rather than
    /// the accent's color.
    var tint: Color?
    var isActive = true
    var size: CGFloat = 30
    @Environment(\.windowAccent) private var accent

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        Image(systemName: symbol)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(isActive ? glyph : Color.secondary)
            .frame(width: size, height: size)
            .background {
                if isActive {
                    shape.fill((tint ?? accent.color).gradient)
                        .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0)],
                                                           startPoint: .top, endPoint: .center)))
                        .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.05)],
                                                                   startPoint: .top, endPoint: .bottom)))
                } else {
                    shape.fill(Palette.wash)
                }
            }
            .accessibilityHidden(true)
    }

    /// White, like an app icon's, except on the window accent, which is too light for it in dark mode.
    private var glyph: Color {
        tint == nil ? accent.onFill : .white
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
    @Environment(\.windowAccent) private var accent
    @ViewState private var hovering = false

    var body: some View {
        configuration.label
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(accent.color.opacity(hovering && isEnabled ? 0.35 : 0), lineWidth: 1))
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
    /// The badge's color while it's on. Without one, the window accent.
    var tint: Color?
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
    @Environment(\.windowAccent) private var accent

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
                        .foregroundStyle(accent.color)
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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.windowAccent) private var accent

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
            .foregroundStyle(isSelected ? accent.color : Color.primary.opacity(0.78))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background {
                let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
                // Fainter in light mode, where the accent's text on it has little room above 4.5:1.
                let selectedFill = accent.color.opacity(colorScheme == .dark ? 0.12 : 0.06)
                shape.fill(isSelected ? AnyShapeStyle(selectedFill) : AnyShapeStyle(Palette.wash))
                    .overlay(shape.strokeBorder(accent.color.opacity(isSelected ? 0.55 : 0), lineWidth: 1.2))
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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.windowAccent) private var accent

    private let knob: CGFloat = 18

    var body: some View {
        GeometryReader { proxy in
            let travel = max(1, proxy.size.width - knob)
            let fraction = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            // A groove filled with the accent's light, glowing in dark mode, and a pearl of white glass to drag.
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track).frame(height: 5)
                Capsule()
                    .fill(accent.gradient)
                    .frame(width: knob / 2 + travel * fraction, height: 5)
                    .shadow(color: accent.color.opacity(colorScheme == .dark ? 0.5 : 0), radius: 4)
                Circle()
                    .fill(LinearGradient(colors: [.white, Color(white: 0.9)], startPoint: .top, endPoint: .bottom))
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.3), radius: 2.5, y: 1.5)
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

/// How far along something is, like an update's download: a thin groove that fills with the accent.
struct MeterBar: View {
    /// From 0 to 1.
    let value: Double
    @Environment(\.windowAccent) private var accent

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule()
                    .fill(accent.color)
                    .frame(width: proxy.size.width * max(0, min(1, value)))
            }
        }
        .frame(height: 5)
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
                Circle().fill(tint ?? accent.color).frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(value)")
                    .font(.system(size: 30, weight: .medium, design: .rounded))
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
                .overlay(Capsule().strokeBorder(Palette.rimGradient))
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
        /// For the header's stage: clear glass, light or dark with the stage.
        case glass
    }

    let title: String
    var symbol: String?
    var kind: Kind = .plain
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.windowAccent) private var accent
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
            // Every kind is a capsule of glass whose top edge catches the light.
            .overlay(Capsule().strokeBorder(rim))
            // In dark mode a prominent button glows with the accent, like a switch that's on.
            .shadow(color: accent.color.opacity(look == .prominent && isDark ? 0.3 : 0), radius: 8)
            // A light-mode prominent button darkens under the pointer instead, so its white label keeps 4.5:1.
            .brightness(hovering && isEnabled ? (look == .prominent && !isDark ? -0.04 : 0.04) : 0)
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle())
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
    }

    private var isDark: Bool { colorScheme == .dark }

    /// A destructive button's red: the window's shade of it, deep in light mode, so its label reads
    /// 4.5:1 on its own faint fill, where the system red read about 3:1 light and 4:1 dark.
    private static let red = WindowAccent(choice: .red).color

    /// A prominent button that's disabled looks plain, the way macOS greys out a default button:
    /// faded along with the accent's fill, its label would all but disappear.
    private var look: Kind { kind == .prominent && !isEnabled ? .plain : kind }

    private var foreground: Color {
        switch look {
        case .plain: .primary
        case .prominent: accent.onFill
        case .destructive: Self.red
        case .glass: isDark ? .white : .primary
        }
    }

    private var background: AnyShapeStyle {
        switch look {
        case .plain: AnyShapeStyle(Palette.wash)
        case .prominent: AnyShapeStyle(accent.gradient)
        // Fainter in light mode, as a selected choice chip is: at 0.12 the red label fell under 4.5:1.
        case .destructive: AnyShapeStyle(Self.red.opacity(isDark ? 0.12 : 0.06))
        case .glass where isDark:
            AnyShapeStyle(LinearGradient(colors: [.white.opacity(hovering ? 0.22 : 0.16), .white.opacity(hovering ? 0.12 : 0.07)],
                                         startPoint: .top, endPoint: .bottom))
        case .glass: AnyShapeStyle(Color.white.opacity(hovering ? 0.9 : 0.75))
        }
    }

    private var rim: LinearGradient {
        switch look {
        case .plain: Palette.rimGradient
        case .prominent: Self.lit(.white.opacity(0.45))
        case .destructive: Self.lit(Self.red.opacity(0.2))
        case .glass where isDark: Self.lit(.white.opacity(0.4))
        case .glass: LinearGradient(colors: [.white, .black.opacity(0.1)], startPoint: .top, endPoint: .bottom)
        }
    }

    /// A rim lit along the top, fading to a tenth of `color` along the bottom.
    private static func lit(_ color: Color) -> LinearGradient {
        LinearGradient(colors: [color, color.opacity(0.1)], startPoint: .top, endPoint: .bottom)
    }
}
