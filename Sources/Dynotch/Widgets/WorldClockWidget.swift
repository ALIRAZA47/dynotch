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
                        VStack(spacing: 6) {
                            ForEach(places, id: \.name) { place in
                                row(place, at: context.date)
                            }
                        }
                    }
                }
            }
        }
    }

    private func row(_ place: WorldPlace, at date: Date) -> some View {
        let clock = WorldTime.clock(at: place, on: date)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(place.name)
                .font(NotchFont.body)
                .foregroundStyle(theme.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let day = clock.day {
                Text(day)
                    .font(NotchFont.caption)
                    .foregroundStyle(theme.tertiary)
            }
            Text(clock.time)
                .font(NotchFont.numeric(13.5))
                .foregroundStyle(theme.primary)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
