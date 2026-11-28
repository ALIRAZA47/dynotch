import SwiftUI

// MARK: Choices

/// What the open notch was made of before Orbit. Orbit draws one solid surface in light or dark,
/// so only `black` is left; the type stays so saved settings and profiles still read.
enum NotchMaterial: String, CaseIterable, Identifiable {
    case black, glass

    var id: String { rawValue }

    var title: String {
        switch self {
        case .black: "Black"
        case .glass: "Glass"
        }
    }

    /// Orbit has no glass. Kept for profiles saved by earlier versions.
    static var isGlassAvailable: Bool { false }
}

/// Light, dark, or whatever macOS is using. The closed notch is black whatever this says, so it
/// blends with the camera housing.
enum NotchAppearance: String, CaseIterable, Identifiable {
    case light, dark, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .system: "Follow macOS"
        }
    }
}

/// Where the section buttons sit around the open notch.
enum SectionPlacement: String, CaseIterable, Identifiable {
    /// One strip stuck under the panel, split by the camera's width.
    case under
    /// A column down each side of the panel.
    case sides
    /// All of them in a column down the left side.
    case left
    /// All of them in a column down the right side.
    case right
    /// In the band beside the camera, in place of the section's title and actions.
    case band
    /// Discs on an arc around the panel's bottom edge.
    case arc
    /// None: the command field and swipes go between sections.
    case hidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .under: "Under the panel"
        case .sides: "Both sides"
        case .left: "Left side"
        case .right: "Right side"
        case .band: "Beside the camera"
        case .arc: "Floating arc"
        case .hidden: "Hidden · type to go"
        }
    }
}

/// Where a row's buttons, like Allow, Pause and Join, appear.
enum RowActionMode: String, CaseIterable, Identifiable {
    /// On the row under the pointer.
    case hover
    /// On every row, all the time.
    case always
    /// A row's main button always; the rest under the pointer.
    case primary
    /// In a bar over the command field, for the row under the pointer.
    case bar
    /// In the band beside the camera, for the row under the pointer.
    case band
    /// Behind a ··· button on each row.
    case menu

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hover: "On hover"
        case .always: "Always shown"
        case .primary: "Main action only"
        case .bar: "Action bar"
        case .band: "Beside the camera"
        case .menu: "··· menu"
        }
    }
}

/// How the panel opens and the strip slides out.
enum NotchMotion: String, CaseIterable, Identifiable {
    case springy, smooth, minimal

    var id: String { rawValue }

    var title: String { rawValue.capitalized }
}

/// What sits beside the camera while the notch is closed.
enum ClosedNotchShows: String, CaseIterable, Identifiable {
    /// A dot per live thing, in the order of the section buttons.
    case dots
    /// The live thing's icon and its figure, as before Orbit.
    case activities
    /// Nothing but the camera housing. Notices that need you still show.
    case nothing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dots: "Status dots"
        case .activities: "Icon and figure"
        case .nothing: "Nothing"
        }
    }
}

/// The color that means "needs you" and marks what's selected.
enum NotchAccent: String, CaseIterable, Identifiable {
    case cobalt, lavender, blue, teal, green, yellow, orange, pink, red, graphite

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    /// The solid face: a selected section button, a switch that's on, a slider's fill.
    var color: Color {
        switch self {
        case .cobalt: NotchTheme.hex(0x2A62F5)
        case .lavender: Color(red: 0.66, green: 0.58, blue: 1.0)
        case .blue: Color(red: 0.36, green: 0.62, blue: 1.0)
        case .teal: Color(red: 0.3, green: 0.8, blue: 0.84)
        case .green: Color(red: 0.4, green: 0.82, blue: 0.48)
        case .yellow: Color(red: 1.0, green: 0.8, blue: 0.3)
        case .orange: Color(red: 1.0, green: 0.6, blue: 0.3)
        case .pink: Color(red: 1.0, green: 0.46, blue: 0.68)
        case .red: Color(red: 1.0, green: 0.4, blue: 0.4)
        case .graphite: Color(red: 0.8, green: 0.8, blue: 0.84)
        }
    }

    #if DEBUG
    /// Stops a run if text on any accent's face, or the accent as text on either panel, reads at
    /// less than 4.5:1.
    static func checkContrast() {
        for accent in allCases {
            for isDark in [true, false] {
                let theme = NotchTheme(accent: accent, isDark: isDark)
                let face = NotchTheme.luminance(of: accent.color)
                let ink = NotchTheme.luminance(of: theme.onAccent)
                assert(NotchTheme.contrast(face, ink) >= 4.5, "Ink on \(accent.title) reads at only \(NotchTheme.contrast(face, ink)):1")
                let text = NotchTheme.luminance(of: theme.accentText)
                let bg = NotchTheme.luminance(of: theme.background)
                assert(NotchTheme.contrast(text, bg) >= 4.5, "\(accent.title) text reads at only \(NotchTheme.contrast(text, bg)):1")
            }
        }
    }
    #endif
}

/// How a surface sits in the open notch. Orbit is flat: a raised surface is a shade off the panel
/// with a hairline round it, a control is a filled shape, a well is the field color with an inset
/// line, and what's selected or on is a solid face of the accent.
enum GlassDepth: Equatable {
    /// A card, a tile, the row under the pointer.
    case pane
    /// A button, a chip, a keycap, a segment's thumb.
    case control
    /// A field, a track, a drop target.
    case well
    /// A soft wash of a color: a focus button, a selected file.
    case tint(Color)
    /// A solid face of a color, with ink on it: the selected section, a switch that's on.
    case lens(Color)
}

// MARK: Theme

/// How the open notch looks: Orbit's colors in light or dark, its roundness and spacing.
/// `AppSettings.theme` builds it from the user's choices; views read it from the environment,
/// where `NotchRootView` puts it.
struct NotchTheme: Equatable {
    var material: NotchMaterial = .black
    /// The accent the user picked. `accent` is its color.
    var accentChoice: NotchAccent
    /// Light or dark, resolved: `NotchRootView` follows macOS when the setting says so. The closed
    /// notch is always dark.
    var isDark: Bool
    /// Button roundness: buttons, switches, rows and fields. 0 is square.
    var radius: CGFloat
    /// The system's Increase Contrast: quieter text and lines come up a step.
    var isHighContrast = false
    /// The system's Reduce Transparency. Orbit is opaque already; kept for the views that ask.
    var reducesTransparency = false

    static let radiusRange: ClosedRange<CGFloat> = 0...16
    /// Kept for profiles and older settings; Orbit's panel corners are fixed.
    static let topRadiusRange: ClosedRange<CGFloat> = 6...20
    static let bottomRadiusRange: ClosedRange<CGFloat> = 16...40

    init(accent: NotchAccent = .cobalt, isDark: Bool = true, radius: CGFloat = 3) {
        accentChoice = accent
        self.isDark = isDark
        self.radius = min(max(radius, Self.radiusRange.lowerBound), Self.radiusRange.upperBound)
    }

    /// For looks named the way they were before Orbit: glass now means the light panel, and the
    /// corners set the button roundness.
    init(material: NotchMaterial, accent: NotchAccent = .cobalt, topRadius: CGFloat = 12, bottomRadius: CGFloat = 30) {
        self.init(accent: accent, isDark: material != .glass, radius: max(0, (bottomRadius - 26) / 2))
    }

    init(accent: NotchAccent, topRadius: CGFloat, bottomRadius: CGFloat) {
        self.init(material: .black, accent: accent, topRadius: topRadius, bottomRadius: bottomRadius)
    }

    static let standard = NotchTheme()

    /// The same look, dark: the closed notch and anything drawn on black.
    var dark: NotchTheme {
        var theme = self
        theme.isDark = true
        return theme
    }

    var colorScheme: ColorScheme { isDark ? .dark : .light }

    /// Orbit has no glass.
    var isGlass: Bool { false }

    // MARK: Shape

    /// The curve where the open panel meets the top edge of the screen.
    var topRadius: CGFloat { Self.panelTopRadius }
    /// The open panel's bottom corners.
    var bottomRadius: CGFloat { Self.panelBottomRadius }
    static let panelTopRadius: CGFloat = 14
    static let panelBottomRadius: CGFloat = 22
    /// The widest top curve a panel has, so the notch's window always has room for it.
    static var maxTopRadius: CGFloat { panelTopRadius }

    /// Cards and surfaces: the button roundness, a little more so a card never looks sharper than
    /// the buttons on it.
    var cardRadius: CGFloat { min(radius + 2, 18) }
    /// Buttons, rows, fields and tiles.
    var controlRadius: CGFloat { radius }
    /// The shape every button and field draws in.
    var controlShape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }
    var cardShape: RoundedRectangle { RoundedRectangle(cornerRadius: cardRadius, style: .continuous) }

    /// The closed notch follows the camera housing's corners, whatever the theme.
    static let closedTopRadius: CGFloat = 6

    static func closedBottomRadius(hasRow: Bool, isHovering: Bool) -> CGFloat {
        hasRow ? 16 : isHovering ? 12 : 10
    }

    // MARK: Spacing

    /// Between the panel's edges and what's in it.
    static let inset: CGFloat = 16
    /// Between cards.
    static let gap: CGFloat = 10
    /// Inside a card.
    static let cardPadding = EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
    /// Between a card's title and what's under it.
    static let titleGap: CGFloat = 8
    /// How tall the buttons in the band beside the camera are.
    static let headerControlHeight: CGFloat = 26
    /// A ranked row in Live, Agents and the lists.
    static let rowHeight: CGFloat = 50
    /// The command field at the panel's foot, and the gap above it.
    static let commandFieldHeight: CGFloat = 40
    static let commandFieldGap: CGFloat = 10

    // MARK: Colors

    /// The panel itself.
    var background: Color { isDark ? Self.hex(0x161618) : Self.hex(0xF6F6F8) }
    /// A raised surface: a card, the row under the pointer.
    var raised: Color { isDark ? Self.hex(0x212124) : .white }
    /// A button's fill, a hover, an empty track.
    var hover: Color { isDark ? Self.hex(0x2A2A2E) : Self.hex(0xEBEBEF) }
    /// Hairlines round surfaces and between rows.
    var line: Color { isDark ? .white.opacity(isHighContrast ? 0.2 : 0.08) : .black.opacity(isHighContrast ? 0.22 : 0.08) }
    /// A field's fill: the command field, a search.
    var field: Color { isDark ? Self.hex(0x0F0F11) : .white }

    /// Titles, values and selected text.
    var primary: Color { isDark ? Self.hex(0xF5F5F7) : Self.hex(0x1D1D1F) }
    /// Second lines, labels and idle controls.
    var secondary: Color { isDark ? Self.hex(isHighContrast ? 0xC7C7CC : 0xA1A1A6) : Self.hex(isHighContrast ? 0x48484C : 0x636368) }
    /// Hints, placeholders, and the counts beside rows.
    var tertiary: Color { isDark ? Self.hex(isHighContrast ? 0xAEAEB2 : 0x98989E) : Self.hex(isHighContrast ? 0x48484C : 0x636368) }
    /// The empty part of a scrubber or a level bar.
    var track: Color { hover }
    /// A line between the parts of a card.
    var divider: Color { line }
    /// Kept for `EtchedDivider`; Orbit's dividers are one hairline.
    var dividerLight: Color { .clear }
    /// A flat hover behind a row in a list.
    var control: Color { hover }
    var controlHover: Color { isDark ? Self.hex(0x323237) : Self.hex(0xE1E1E6) }

    /// Picks out what's selected, and means "needs you".
    var accent: Color { accentChoice.color }
    /// The accent as text on the panel: lifted in dark, deepened in light, to 4.5:1.
    var accentText: Color {
        if accentChoice == .cobalt { return isDark ? Self.hex(0x7FA6FF) : Self.hex(0x1F55D6) }
        return Self.legible(accent, on: background)
    }
    /// A soft wash of the accent behind a focus button or a row that needs you.
    var accentSoft: Color { accent.opacity(isDark ? 0.16 : 0.12) }
    /// The thin border on a focus button.
    var edge: Color { isDark ? Self.hex(0xF5F5F7).opacity(0.72) : Self.hex(0x1D1D1F).opacity(0.7) }
    /// Something live: a playing track, a run in progress.
    var live: Color { isDark ? Self.hex(0x30D158) : Self.hex(0x1E8E3E) }
    /// Recording, failed, a risky button.
    var alert: Color { isDark ? Self.hex(0xFF453A) : Self.hex(0xD70015) }
    /// Text and symbols on the accent's solid face: white where it reads, ink where it doesn't.
    var onAccent: Color {
        Self.contrast(Self.luminance(of: accent), 1) >= 4.5 ? .white : Self.hex(0x141024)
    }
    /// A date that has passed.
    var overdue: Color { alert }

    // MARK: Surfaces

    /// A surface's fill. `isLit` is the highlight under the pointer.
    func fill(_ depth: GlassDepth, isLit: Bool = false) -> Color {
        switch depth {
        case .pane: isLit ? hover : raised
        case .control: isLit ? controlHover : hover
        case .well: field
        case .tint(let color): color.opacity((isDark ? 0.16 : 0.12) + (isLit ? 0.06 : 0))
        case .lens(let color): color
        }
    }

    /// The hairline round a surface, or none.
    func rim(_ depth: GlassDepth, isLit: Bool = false) -> Color {
        switch depth {
        case .pane, .well: line
        case .control: .clear
        case .tint(let color): color.opacity(isLit ? 0.5 : 0.32)
        case .lens: .clear
        }
    }

    /// Orbit has no sheen. Kept for callers from before it.
    func sheen(_ depth: GlassDepth) -> Double { 0 }

    /// Text and symbols on a surface: ink on the accent's face, the primary color elsewhere.
    func ink(on depth: GlassDepth) -> Color {
        if case .lens(let color) = depth {
            return Self.contrast(Self.luminance(of: color), 1) >= 4.5 ? .white : Self.hex(0x141024)
        }
        return primary
    }

    // MARK: Helpers

    static func hex(_ value: UInt32) -> Color {
        Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255)
    }

    static func luminance(of color: Color) -> Double {
        Luminance.rgb(of: NSColor(color)).map(Luminance.of) ?? 0
    }

    static func contrast(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// `color` moved toward white or black, whichever `background` is far from, just far enough to
    /// read at 4.6:1 on it.
    static func legible(_ color: Color, on background: Color) -> Color {
        guard let rgb = Luminance.rgb(of: NSColor(color)) else { return color }
        let bg = luminance(of: background)
        if contrast(Luminance.of(rgb), bg) >= 4.6 { return color }
        let towardWhite = bg < 0.2
        var low = 0.0, high = 1.0
        func mixed(_ t: Double) -> [Double] {
            rgb.map { towardWhite ? $0 + (1 - $0) * t : $0 * (1 - t) }
        }
        for _ in 0..<14 {
            let mid = (low + high) / 2
            if contrast(Luminance.of(mixed(mid)), bg) < 4.6 { low = mid } else { high = mid }
        }
        let out = mixed(high)
        return Color(.sRGB, red: out[0], green: out[1], blue: out[2])
    }
}

// MARK: Surface

/// What the notch is drawn on. Closed, and in a glance, it's black so it blends with the camera
/// housing. Open, it's Orbit's panel in light or dark with a hairline round it.
struct NotchSurface: View {
    var isOpen: Bool
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    @Environment(\.notchTheme) private var theme

    var body: some View {
        ZStack {
            Color.black
            if isOpen {
                theme.background
                    .transition(.opacity)
                NotchShape(topRadius: topRadius, bottomRadius: bottomRadius, includesTopEdge: false)
                    .stroke(theme.line, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }
}

extension NotchSurface {
    /// For the drawings in Settings from before Orbit: plain black.
    init(isGlass: Bool, topRadius: CGFloat, bottomRadius: CGFloat, bandHeight: CGFloat = 0) {
        self.init(isOpen: false, topRadius: topRadius, bottomRadius: bottomRadius)
    }
}

private struct NotchThemeKey: EnvironmentKey {
    static let defaultValue = NotchTheme.standard
}

extension EnvironmentValues {
    var notchTheme: NotchTheme {
        get { self[NotchThemeKey.self] }
        set { self[NotchThemeKey.self] = newValue }
    }
}

// MARK: Type

/// Orbit's type: SF Pro for words, SF Mono for times and figures. Weight does the rest.
enum NotchFont {
    /// Small capitals over a group: UP NEXT, BATTERIES. In secondary.
    static let label = Font.system(size: 11, weight: .semibold)
    /// The line under a row's second line, a device's status.
    static let caption = Font.system(size: 11, weight: .medium)
    /// Messages in empty states.
    static let footnote = Font.system(size: 12)
    /// Rows, fields and chips.
    static let body = Font.system(size: 13, weight: .regular)
    /// Button titles, the selected segment.
    static let bodyStrong = Font.system(size: 13, weight: .medium)
    /// A row's second line, the artist under the track.
    static let subheadline = Font.system(size: 12.5, weight: .regular)
    /// A row's first line, a tile's name.
    static let headline = Font.system(size: 14, weight: .semibold)
    /// A glance's first line.
    static let glanceTitle = Font.system(size: 14, weight: .semibold)
    /// The section's title in the band beside the camera.
    static let title = Font.system(size: 17, weight: .semibold)
    /// What to type: a command's hint like `tea 4m`, a hex code.
    static let mono = Font.system(size: 11.5, weight: .medium, design: .monospaced)
    /// The keys on a keycap: ⌃ ⌥ K, esc, ↩.
    static let keycap = Font.system(size: 11, weight: .medium, design: .monospaced)

    /// A section's one big line: the track title over the art.
    static func display(_ size: CGFloat = 22) -> Font {
        .system(size: size, weight: .bold)
    }

    /// Times, temperatures and percentages in running text.
    static func numeric(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }

    /// A row's time, a section button's figure: SF Mono.
    static func time(_ size: CGFloat = 14, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// A big figure that is the point of its view: the focus dial's time, a countdown.
    static func figure(_ size: CGFloat) -> Font {
        .system(size: size, weight: size >= 24 ? .medium : .semibold, design: .monospaced)
    }
}
