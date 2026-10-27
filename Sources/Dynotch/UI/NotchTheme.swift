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
    var isGlass: Bool { material == .glass && NotchMaterial.isGlassAvailable }

    // MARK: Spacing

    /// Between the open notch's edges and the cards, so the cards' corners follow the notch's.
    static let inset: CGFloat = 16
    /// Between cards.
    static let gap: CGFloat = 12
    /// Inside a card. A little less above and below, where line spacing already adds room.
    static let cardPadding = EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
    /// Between a card's title and what's under it.
    static let titleGap: CGFloat = 6

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

    var primary: Color { .white }
    /// Second lines, values and idle controls.
    var secondary: Color { .white.opacity(isGlass ? 0.68 : 0.6) }
    /// Card titles, hints and placeholders. No fainter, so small text stays readable.
    var tertiary: Color { .white.opacity(isGlass ? 0.56 : 0.5) }
    /// The empty part of a meter or a ring.
    var track: Color { .white.opacity(isGlass ? 0.22 : 0.16) }
    var card: Color { .white.opacity(isGlass ? 0.1 : 0.06) }
    var cardHover: Color { .white.opacity(isGlass ? 0.15 : 0.1) }
    /// A hairline that keeps a card's edge crisp.
    var cardStroke: Color { .white.opacity(isGlass ? 0.12 : 0.06) }
    /// Between the parts of a card.
    var divider: Color { .white.opacity(isGlass ? 0.12 : 0.07) }
    /// Fields and buttons inside a card.
    var control: Color { .white.opacity(isGlass ? 0.12 : 0.08) }
    var controlHover: Color { .white.opacity(isGlass ? 0.18 : 0.14) }
    /// Behind the selected tab, day or file.
    var selection: Color { accent.opacity(0.26) }
    /// Behind a selected file or clipboard item, inside a ring of `selectionRing`.
    var selectionFill: Color { accent.opacity(0.16) }
    var selectionRing: Color { accent.opacity(0.6) }
    /// Text and symbols on a button filled with the accent.
    var onAccent: Color { Color(red: 0.08, green: 0.06, blue: 0.17) }
}

/// What the notch is made of: black, or Liquid Glass when `isGlass`. Glass stays black along the
/// top, `bandHeight` deep, where it meets the camera housing and the menu bar, and clears below.
/// Snapshots can't draw glass, so they get a dark, see-through stand-in.
struct NotchSurface: View {
    var isGlass: Bool
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var bandHeight: CGFloat = 0
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        ZStack {
            Color.black.opacity(isGlass ? 0 : 1)
            if isGlass {
                ZStack {
                    glass
                    band
                }
                .transition(.opacity)
            }
        }
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
            // A little darker than plain glass, so white text stays easy to read over a bright wallpaper.
            Rectangle().fill(.clear).glassEffect(.regular.tint(Color.black.opacity(0.32)), in: shape)
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
/// the rest. Numbers use the rounded face with digits of one width, so they don't jitter as they change.
enum NotchFont {
    /// Card titles: Up next, Timers, Batteries.
    static let label = Font.system(size: 11, weight: .semibold)
    /// The line under a row: a due date, when an event starts, a device's status.
    static let caption = Font.system(size: 10, weight: .medium)
    /// Hints and messages in empty cards.
    static let footnote = Font.system(size: 11)
    /// Rows, fields and buttons.
    static let body = Font.system(size: 11.5, weight: .medium)
    /// The selected row, the selected tab, button titles.
    static let bodyStrong = Font.system(size: 11.5, weight: .semibold)
    /// The artist under the track title.
    static let subheadline = Font.system(size: 12.5, weight: .medium)
    /// The first line of a tile or drop zone.
    static let headline = Font.system(size: 13, weight: .semibold)
    /// The track title.
    static let title = Font.system(size: 15, weight: .semibold)

    /// Times, temperatures and percentages.
    static func numeric(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
}
