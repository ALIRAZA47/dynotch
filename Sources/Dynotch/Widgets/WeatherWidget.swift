import SwiftUI

/// The weather for the city picked in Settings, or where the Mac is: now, today's high and low,
/// and rain on the way.
struct WeatherWidget: View {
    @ObservedObject private var weather = WeatherService.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        WidgetCard(title: weather.placeName.isEmpty ? "Weather" : weather.placeName,
                   symbol: settings.weatherUsesLocation ? "location.fill" : "cloud.sun.fill") {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch weather.status {
        case .needsPlace:
            PermissionPrompt(symbol: "cloud.sun", message: "See the weather for your city.", buttonTitle: "Choose a City") {
                SettingsWindowController.shared.show(page: .nook)
            }
        case .locationOff:
            PermissionPrompt(symbol: "location.slash", message: "Dynotch can't use Location Services.",
                             buttonTitle: "Open Settings", action: weather.requestLocationAccess)
        default:
            if let conditions = weather.conditions {
                ConditionsView(conditions: conditions, units: settings.weatherUnits)
            } else if weather.status == .failed {
                PermissionPrompt(symbol: "wifi.exclamationmark", message: "Couldn't load the weather.",
                                 buttonTitle: "Try Again", action: weather.refresh)
            } else {
                EmptyState(symbol: weather.status == .locating ? "location" : "cloud",
                           message: weather.status == .locating ? "Finding where you are…" : "Loading…")
            }
        }
    }
}

/// Now in a big SF Mono figure with the sky beside it, a few words for it, today's high and low,
/// and rain on the way in the accent at the foot.
private struct ConditionsView: View {
    let conditions: WeatherService.Conditions
    let units: TemperatureUnits
    @Environment(\.notchTheme) private var theme

    var body: some View {
        let sky = Sky(code: conditions.code, isDay: conditions.isDay)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Text(WeatherService.format(conditions.temperature, units: units))
                    .font(NotchFont.figure(40))
                    .foregroundStyle(theme.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 0)
                Image(systemName: sky.symbol)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(theme.primary)
                    .accessibilityHidden(true)
            }
            Text(sky.description)
                .font(NotchFont.headline)
                .foregroundStyle(theme.primary)
                .lineLimit(1)
                .padding(.top, 4)
            Text("High \(WeatherService.format(conditions.high, units: units)) · Low \(WeatherService.format(conditions.low, units: units))")
                .font(NotchFont.time(11.5, .medium))
                .foregroundStyle(theme.secondary)
                .lineLimit(1)
                .padding(.top, 2)
            Spacer(minLength: 6)
            rain
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var rain: some View {
        if let start = conditions.rainStart {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                rainLine("Rain \(Format.countdown(to: start, from: context.date))")
            }
        } else if conditions.isRaining {
            rainLine("Raining now")
        }
    }

    /// A hairline, then the umbrella and when, in the accent: rain is the thing to look at.
    private func rainLine(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            theme.line.frame(height: 1)
            Label(text, systemImage: "umbrella.fill")
                .font(NotchFont.bodyStrong)
                .foregroundStyle(theme.accentText)
                .lineLimit(1)
        }
    }
}

/// A WMO weather code as an SF Symbol and a few words.
struct Sky {
    let symbol: String
    let description: String

    init(code: Int, isDay: Bool) {
        switch code {
        case 0: (symbol, description) = (isDay ? "sun.max.fill" : "moon.stars.fill", "Clear")
        case 1: (symbol, description) = (isDay ? "sun.max.fill" : "moon.fill", "Mostly clear")
        case 2: (symbol, description) = (isDay ? "cloud.sun.fill" : "cloud.moon.fill", "Partly cloudy")
        case 3: (symbol, description) = ("cloud.fill", "Cloudy")
        case 45, 48: (symbol, description) = ("cloud.fog.fill", "Fog")
        case 51, 53, 55: (symbol, description) = ("cloud.drizzle.fill", "Drizzle")
        case 56, 57: (symbol, description) = ("cloud.sleet.fill", "Freezing drizzle")
        case 61: (symbol, description) = ("cloud.rain.fill", "Light rain")
        case 63: (symbol, description) = ("cloud.rain.fill", "Rain")
        case 65: (symbol, description) = ("cloud.heavyrain.fill", "Heavy rain")
        case 66, 67: (symbol, description) = ("cloud.sleet.fill", "Freezing rain")
        case 71: (symbol, description) = ("cloud.snow.fill", "Light snow")
        case 73, 77: (symbol, description) = ("cloud.snow.fill", "Snow")
        case 75: (symbol, description) = ("cloud.snow.fill", "Heavy snow")
        case 80, 81: (symbol, description) = (isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill", "Showers")
        case 82: (symbol, description) = ("cloud.heavyrain.fill", "Heavy showers")
        case 85, 86: (symbol, description) = ("cloud.snow.fill", "Snow showers")
        case 95: (symbol, description) = ("cloud.bolt.rain.fill", "Thunderstorms")
        case 96, 99: (symbol, description) = ("cloud.bolt.rain.fill", "Thunderstorms, hail")
        default: (symbol, description) = ("cloud.fill", "")
        }
    }
}
