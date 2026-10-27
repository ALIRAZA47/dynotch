import SwiftUI

/// How the open notch looks: the colors, corners and spacing everything in it draws with.
/// Views read it from the environment, where `NotchRootView` puts it.
struct NotchTheme: Equatable {
    /// Picks out the selected tab, selections and the main buttons.
    var accent = Color(red: 0.66, green: 0.58, blue: 1.0)
    /// The curve where the open notch meets the top edge of the screen.
    var topRadius: CGFloat = 12
    /// The open notch's bottom corners. The cards inside follow them.
    var bottomRadius: CGFloat = 30
    /// The open notch is see-through glass rather than black, so what's on it needs a little more contrast.
    var isGlass = false

    static let standard = NotchTheme()

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
    static let maxTopRadius: CGFloat = 20

    /// The closed notch follows the camera housing's corners, whatever the theme.
    static let closedTopRadius: CGFloat = 6

    static func closedBottomRadius(hasRow: Bool, isHovering: Bool) -> CGFloat {
        hasRow ? 16 : isHovering ? 12 : 10
    }

    // MARK: Colors

    var primary: Color { .white }
    /// Second lines, values and idle controls.
    var secondary: Color { .white.opacity(isGlass ? 0.68 : 0.6) }
    /// Card titles, hints and placeholders.
    var tertiary: Color { .white.opacity(isGlass ? 0.48 : 0.38) }
    /// The empty part of a meter or a ring.
    var track: Color { .white.opacity(isGlass ? 0.22 : 0.16) }
    var card: Color { .white.opacity(isGlass ? 0.1 : 0.07) }
    var cardHover: Color { .white.opacity(isGlass ? 0.15 : 0.11) }
    /// A hairline that keeps a card's edge crisp.
    var cardStroke: Color { .white.opacity(isGlass ? 0.12 : 0.05) }
    /// Fields and buttons inside a card.
    var control: Color { .white.opacity(isGlass ? 0.12 : 0.08) }
    var controlHover: Color { .white.opacity(isGlass ? 0.18 : 0.14) }
    /// Behind the selected tab, day or file.
    var selection: Color { accent.opacity(0.28) }
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
    /// Card titles, in capitals: TIMERS, REMINDERS.
    static let label = Font.system(size: 9.5, weight: .bold)
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
