import SwiftUI

/// The time in the cities picked in Settings, with the day where it isn't today here. It's all worked
/// out on the Mac, once a minute while it's on screen.
struct WorldClockWidget: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.notchTheme) private var theme

    var body: some View {
        let places = settings.worldClockCities.compactMap(WorldTime.place)
        WidgetCard(title: "World clock", symbol: "globe") {
            if places.isEmpty {
                PermissionPrompt(symbol: "globe", message: "See the time in other cities.", buttonTitle: "Choose Cities") {
                    SettingsWindowController.shared.show(page: .nook)
                }
            } else {
                TimelineView(.everyMinute) { context in
                    Scroller(.vertical, fadesOverflow: true) {
                        VStack(spacing: 0) {
                            ForEach(Array(places.enumerated()), id: \.element.name) { index, place in
                                if index > 0 { theme.line.frame(height: 1) }
                                row(place, at: context.date)
                            }
                        }
                    }
                }
            }
        }
    }

    /// The city, the day where it isn't today here, and the time in SF Mono.
    private func row(_ place: WorldPlace, at date: Date) -> some View {
        let clock = WorldTime.clock(at: place, on: date)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(place.name)
                .font(NotchFont.bodyStrong)
                .foregroundStyle(theme.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let day = clock.day {
                Text(day)
                    .font(NotchFont.caption)
                    .foregroundStyle(theme.secondary)
            }
            Text(clock.time)
                .font(NotchFont.time(15))
                .foregroundStyle(theme.primary)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(maxWidth: .infinity)
        .frame(height: 34)
        .accessibilityElement(children: .combine)
    }
}
