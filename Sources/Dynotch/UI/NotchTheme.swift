import SwiftUI

/// What the open notch is made of. The closed notch is always black, so it blends with the camera housing.
enum NotchMaterial: String, CaseIterable, Identifiable {
    case black, glass

    var id: String { rawValue }

    var title: String {
        switch self {
        case .black: "Black"
        case .glass: "Glass"
        }
    }

    /// Glass is Liquid Glass, which macOS has from version 26.
    static var isGlassAvailable: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }
}

/// The color the open notch picks things out in. Each is light enough to read on black.
enum NotchAccent: String, CaseIterable, Identifiable {
    case lavender, blue, teal, green, yellow, orange, pink, red, graphite

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var color: Color {
        switch self {
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
    /// Stops a run if ink, `NotchTheme.onAccent`, reads at less than 4.5:1 on any accent, so a new
    /// accent can't make the selected tab or a tile that's on hard to read.
    static func checkContrast() {
        let ink = luminance(of: NotchTheme.standard.onAccent)
        for accent in allCases {
            let face = luminance(of: accent.color)
            let ratio = (max(face, ink) + 0.05) / (min(face, ink) + 0.05)
            assert(ratio >= 4.5, "Ink on \(accent.title) reads at only \(ratio):1")
        }
    }

    private static func luminance(of color: Color) -> Double {
        Luminance.rgb(of: NSColor(color)).map(Luminance.of) ?? 0
    }
    #endif
}

/// How deep a surface sits in the open notch. The notch is a slab of dark glass lit from above:
/// raised glass catches the light along its top edge and fades toward its foot, glass pressed into
/// the slab catches it on its bottom lip, and whatever is selected or on is a solid jewel of a color.
enum GlassDepth: Equatable {
    /// A card or a tile standing on the slab, the Tray's shelf, a picked row.
    case pane
    /// A button, a chip, a keycap, the command pill, a segment's thumb: a smaller, brighter piece of glass.
    case control
    /// Pressed into the slab: a tab or segment track, a field, a slider's channel, a drop target.
    case well
    /// Glass holding a color's light: a pill button, a glance's disc, a selected Tray file.
    case tint(Color)
    /// A solid jewel of a color, with ink on it: the selected tab, a tile that's on, a targeted drop zone.
    case lens(Color)
}

/// How the open notch looks: the colors, corners and spacing everything in it draws with.
/// `AppSettings.theme` builds it from the user's choices; views read it from the environment,
/// where `NotchRootView` puts it.
struct NotchTheme: Equatable {
    var material: NotchMaterial
    /// The accent the user picked. `accent` is its color.
    var accentChoice: NotchAccent
    /// The curve where the open notch meets the top edge of the screen.
    var topRadius: CGFloat
    /// The open notch's bottom corners. The cards inside follow them.
    var bottomRadius: CGFloat
    /// The system's Increase Contrast: quieter text, tracks and lit edges come up a step.
    /// `NotchRootView` sets it, so `AppSettings.theme` leaves it off.
    var isHighContrast = false
    /// The system's Reduce Transparency: the open notch stays black, whatever its material.
    /// Set beside `isHighContrast`.
    var reducesTransparency = false

    static let topRadiusRange: ClosedRange<CGFloat> = 6...20
    static let bottomRadiusRange: ClosedRange<CGFloat> = 16...40

    init(material: NotchMaterial = .black, accent: NotchAccent = .lavender, topRadius: CGFloat = 12, bottomRadius: CGFloat = 30) {
        self.material = material
        accentChoice = accent
        self.topRadius = min(max(topRadius, Self.topRadiusRange.lowerBound), Self.topRadiusRange.upperBound)
        self.bottomRadius = min(max(bottomRadius, Self.bottomRadiusRange.lowerBound), Self.bottomRadiusRange.upperBound)
    }

    static let standard = NotchTheme()

    /// Picks out the selected tab, selections and the main buttons.
    var accent: Color { accentChoice.color }
    /// See-through glass rather than black, so what's on it needs a little more contrast.
    var isGlass: Bool { material == .glass && NotchMaterial.isGlassAvailable && !reducesTransparency }

    // MARK: Spacing

    /// Between the open notch's edges and the cards, so the cards' corners follow the notch's.
    static let inset: CGFloat = 16
    /// Between cards.
    static let gap: CGFloat = 12
    /// Inside a card. A little less above and below, where line spacing already adds room.
    static let cardPadding = EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
    /// Between a card's title and what's under it.
    static let titleGap: CGFloat = 6
    /// How tall every control in the header is: the tab track, the command pill and the ··· disc.
    static let headerControlHeight: CGFloat = 28

    // MARK: Corners

    /// Cards sit `inset` in from the notch's bottom corners and keep the same center.
    var cardRadius: CGFloat { max(6, bottomRadius - Self.inset) }
    /// Fields, rows and tiles inside a card: rounder or squarer along with the cards.
    var controlRadius: CGFloat { min(10, max(5, (cardRadius / 2).rounded())) }

    /// The widest top curve a theme can have, so the notch's window always has room for it.
    static var maxTopRadius: CGFloat { topRadiusRange.upperBound }

    /// The closed notch follows the camera housing's corners, whatever the theme.
    static let closedTopRadius: CGFloat = 6

    static func closedBottomRadius(hasRow: Bool, isHovering: Bool) -> CGFloat {
        hasRow ? 16 : isHovering ? 12 : 10
    }

    // MARK: Colors

    /// Titles, values and selected text.
    var primary: Color { .white }
    /// Card labels, bylines, second lines and idle controls. A card's label is never dimmer.
    var secondary: Color { .white.opacity(isHighContrast ? 0.78 : isGlass ? 0.7 : 0.62) }
    /// Hints, placeholders, and the times and counts beside rows. Never a card's label.
    var tertiary: Color { .white.opacity(isHighContrast ? 0.66 : isGlass ? 0.58 : 0.5) }
    /// The empty part of a scrubber or a level bar.
    var track: Color { .white.opacity((isGlass ? 0.2 : 0.14) + contrastLift) }
    /// The groove of `EtchedDivider`, between the parts of a card.
    var divider: Color { .black.opacity(isGlass ? 0.32 : 0.55) }
    /// The lit lower line of `EtchedDivider`, where the groove's edge catches the light.
    var dividerLight: Color { .white.opacity((isGlass ? 0.1 : 0.06) + contrastLift) }
    /// A flat hover behind a row in a list. Anything bigger is `GlassDepth` glass.
    var control: Color { .white.opacity(isGlass ? 0.12 : 0.08) }
    var controlHover: Color { .white.opacity(isGlass ? 0.18 : 0.14) }
    /// Ink: text and symbols on any accent face, at 0.8 for second lines. White on an accent is
    /// hard to read, on the light ones most of all.
    var onAccent: Color { Color(red: 0.08, green: 0.06, blue: 0.17) }
    /// A date that has passed. The system's red reads under 4.5:1 on a pane of glass, so glass has its own.
    var overdue: Color { isGlass ? Color(red: 1, green: 0.5, blue: 0.46) : .red }

    /// What Increase Contrast adds to tracks and lines.
    private var contrastLift: Double { isHighContrast ? 0.06 : 0 }

    // MARK: Light

    /// A surface's fill, top to bottom: raised glass is brightest under the light and falls off
    /// toward its foot, a well the other way up. On Liquid Glass a pane darkens the glass instead,
    /// so it never brightens what's under a label. `isLit` is the highlight under the pointer; a
    /// lens shows it as brightness instead (see `GlassSurface`).
    func fill(_ depth: GlassDepth, isLit: Bool = false) -> LinearGradient {
        let lift = isLit ? 0.05 : 0
        let colors: [Color] = switch depth {
        case .pane:
            isGlass ? [.black.opacity(isLit ? 0.12 : 0.18), .black.opacity(isLit ? 0.12 : 0.18)]
                : [.white.opacity(0.1 + lift), .white.opacity(0.028 + lift)]
        case .control:
            [.white.opacity((isGlass ? 0.13 : 0.125) + lift), .white.opacity((isGlass ? 0.07 : 0.06) + lift)]
        // Darker than the glass, so it reads as cut into it. On black only a breath lighter, enough to see.
        case .well:
            isGlass ? [.black.opacity(isLit ? 0.3 : 0.34), .black.opacity(isLit ? 0.16 : 0.2)]
                : [.white.opacity(isLit ? 0.065 : 0.025), .white.opacity(isLit ? 0.1 : 0.06)]
        case .tint(let color):
            [color.opacity(0.32 + lift), color.opacity(0.16 + lift)]
        case .lens(let color):
            [color, color]
        }
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }

    /// The 1 pt specular rim around a surface: bright where its edge faces the light, dim down the
    /// sides, with a little light bounced back along the far edge. A pane is lit from up and to the
    /// left, so its top-left corner shines and its bottom-right one glints; a well catches the light
    /// on its lower lip. Increase Contrast brightens whichever edge is lit.
    func rim(_ depth: GlassDepth, isLit: Bool = false) -> LinearGradient {
        let lift = (isLit ? 0.1 : 0) + (isHighContrast ? 0.15 : 0)
        switch depth {
        case .pane:
            let (lit, side, far) = isGlass ? (0.36, 0.08, 0.16) : (0.26, 0.04, 0.1)
            return LinearGradient(stops: [.init(color: .white.opacity(lit + lift), location: 0),
                                          .init(color: .white.opacity(side), location: 0.4),
                                          .init(color: .white.opacity(side), location: 0.7),
                                          .init(color: .white.opacity(far), location: 1)],
                                  startPoint: UnitPoint(x: 0.3, y: 0), endPoint: UnitPoint(x: 0.7, y: 1))
        case .control:
            let (lit, side, far) = isGlass ? (0.34, 0.1, 0.12) : (0.26, 0.06, 0.07)
            return Self.vertical(.white.opacity(lit + lift), .white.opacity(side), .white.opacity(far))
        case .well:
            let lip = (isGlass ? 0.24 : 0.15) + (isHighContrast ? 0.15 : 0)
            return Self.vertical(.black.opacity(0.5), .white.opacity(0.03), .white.opacity(lip))
        case .tint(let color):
            return Self.vertical(.white.opacity(0.34 + lift), color.opacity(0.2), color.opacity(0.34))
        case .lens:
            // Light on the top edge, clear down the sides, a little shade along the foot.
            let lit = 0.55 + (isHighContrast ? 0.15 : 0)
            return LinearGradient(stops: [.init(color: .white.opacity(lit), location: 0),
                                          .init(color: .white.opacity(0), location: 0.45),
                                          .init(color: .black.opacity(0), location: 0.45),
                                          .init(color: .black.opacity(0.2), location: 1)],
                                  startPoint: .top, endPoint: .bottom)
        }
    }

    /// How bright the light is across the upper part of raised glass, where it curves toward the
    /// light. A pane on Liquid Glass has none: there it would sit right under the labels.
    func sheen(_ depth: GlassDepth) -> Double {
        switch depth {
        case .pane: isGlass ? 0 : 0.05
        case .control: isGlass ? 0.06 : 0.08
        case .well: 0
        case .tint: 0.08
        case .lens: 0.24
        }
    }

    /// Text and symbols on a surface: ink on a lens's solid color, white on glass.
    func ink(on depth: GlassDepth) -> Color {
        if case .lens = depth { return onAccent }
        return primary
    }

    private static func vertical(_ lit: Color, _ side: Color, _ far: Color) -> LinearGradient {
        LinearGradient(stops: [.init(color: lit, location: 0), .init(color: side, location: 0.45),
                               .init(color: far, location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }
}

/// What the notch is made of: black, or Liquid Glass when `isGlass`. Glass stays black along the
/// top, `bandHeight` deep, where it meets the camera housing and the menu bar, and clears below.
/// Snapshots can't draw glass, so they get a dark, see-through stand-in.
struct NotchSurface: View {
    var isGlass: Bool
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var bandHeight: CGFloat = 0
    /// For the open notch on black: a fine line just inside its sides and bottom, catching the
    /// light toward the foot. Glass lights its own edge, and the closed notch and the glance stay
    /// plain black, so they blend with the camera housing.
    var chamfer = false
    @Environment(\.isSnapshot) private var isSnapshot

    /// How much black lies over Liquid Glass. It's the least that keeps every label at 4.5:1 over a
    /// bright wallpaper; below that, glass goes pale behind white text. The glass's own tint can't
    /// do this: raised, it only lightens the glass.
    private static let glassScrim = 0.5

    var body: some View {
        ZStack {
            Color.black.opacity(isGlass ? 0 : 1)
            if isGlass {
                ZStack {
                    glass
                    band
                }
                .transition(.opacity)
            } else if chamfer {
                chamferLine
                    .transition(.opacity)
            }
        }
    }

    /// Drawn 1.5 points in from the outline, so the silhouette's own edge stays black and no grey
    /// line shows against a light wallpaper. Clear down to just short of halfway, or to the foot of
    /// the band if that's lower, then brightening toward the bottom.
    private var chamferLine: some View {
        GeometryReader { proxy in
            let start = min(1, max(bandHeight / max(proxy.size.height, 1), 0.45))
            NotchShape(topRadius: topRadius, bottomRadius: max(0, bottomRadius - 1.5), includesTopEdge: false)
                .stroke(LinearGradient(stops: [.init(color: .white.opacity(0), location: start),
                                               .init(color: .white.opacity(0.12), location: 1)],
                                       startPoint: .top, endPoint: .bottom), lineWidth: 1)
                .padding(EdgeInsets(top: 0, leading: 1.5, bottom: 1.5, trailing: 1.5))
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var glass: some View {
        let shape = NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
        if isSnapshot {
            ZStack {
                shape.fill(Color(white: 0.05).opacity(0.62))
                shape.fill(LinearGradient(colors: [.white.opacity(0.1), .white.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                NotchShape(topRadius: topRadius, bottomRadius: bottomRadius, includesTopEdge: false)
                    .stroke(Color.white.opacity(0.24), lineWidth: 1)
            }
        } else if #available(macOS 26, *) {
            ZStack {
                Rectangle().fill(.clear).glassEffect(.regular.tint(Color.black.opacity(0.32)), in: shape)
                shape.fill(Color.black.opacity(Self.glassScrim))
            }
        } else {
            Color.black
        }
    }

    /// Keeps the tabs clear of the menu bar behind them, and lets the camera housing blend in.
    /// It's solid down to the menu bar's bottom edge: any less and the menu bar's text shows through.
    private var band: some View {
        GeometryReader { proxy in
            let height = max(proxy.size.height, 1)
            LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: min(1, bandHeight / height)),
                .init(color: .black.opacity(0), location: min(1, (bandHeight + 16) / height)),
            ], startPoint: .top, endPoint: .bottom)
        }
        .opacity(bandHeight > 0 ? 1 : 0)
        .allowsHitTesting(false)
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

/// The notch's type scale: SF Pro in a few sizes, small enough for the notch, with weight doing
/// the rest. Each tab has one bold line to read first; everything else steps down from it. Numbers
/// use the rounded face with digits of one width, so they don't jitter as they change.
enum NotchFont {
    /// Card titles, slider names, Results and Try: Up next, Timers, Batteries. In secondary.
    static let label = Font.system(size: 11, weight: .semibold)
    /// The line under a row: a due date, when an event starts, a device's status.
    static let caption = Font.system(size: 10, weight: .medium)
    /// Messages in empty cards.
    static let footnote = Font.system(size: 11)
    /// Rows, fields and chips.
    static let body = Font.system(size: 11.5, weight: .medium)
    /// The selected tab, the selected segment, button titles.
    static let bodyStrong = Font.system(size: 11.5, weight: .semibold)
    /// The artist and album under the track title.
    static let subheadline = Font.system(size: 12.5, weight: .medium)
    /// The first line of a tile or drop zone.
    static let headline = Font.system(size: 13, weight: .semibold)
    /// A glance's first line, under the camera: the track, the event, the notice, the download.
    static let glanceTitle = Font.system(size: 14, weight: .semibold)
    /// A card's key line: the next event, Nothing playing, the Pomodoro phase.
    static let title = Font.system(size: 17, weight: .bold)
    /// What to type, and nothing else: a command's hint like `tea 4m`, a hex code. Never words.
    static let mono = Font.system(size: 11, weight: .medium, design: .monospaced)
    /// The keys on a keycap: ⌃ ⌥ K, esc, ↩.
    static let keycap = Font.system(size: 10, weight: .bold, design: .rounded)

    /// A tab's one line to read first: the track title, or the Nook's display line. 17 beside
    /// art under 64 points.
    static func display(_ size: CGFloat = 19) -> Font {
        .system(size: size, weight: .bold)
    }

    /// Times, temperatures and percentages.
    static func numeric(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }

    /// A big figure that is the point of its view: the focus dial's time, a glance's countdown, the
    /// temperature. From 20 points SF Pro switches to its display cut, which reads best a weight
    /// lighter, so the figure stays crisp on glass instead of turning into a slab.
    static func figure(_ size: CGFloat) -> Font {
        numeric(size, size >= 20 ? .medium : .semibold)
    }
}
