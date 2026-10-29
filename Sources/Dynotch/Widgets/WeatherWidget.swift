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

private struct ConditionsView: View {
    let conditions: WeatherService.Conditions
    let units: TemperatureUnits
    @Environment(\.notchTheme) private var theme

    var body: some View {
        let sky = Sky(code: conditions.code, isDay: conditions.isDay)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: sky.symbol)
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 26))
                    .frame(width: 34)
                Text(WeatherService.format(conditions.temperature, units: units))
                    .font(NotchFont.figure(30))
                    .foregroundStyle(theme.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(sky.description)
                .font(NotchFont.body)
                .foregroundStyle(theme.secondary)
                .lineLimit(1)
            Text("H \(WeatherService.format(conditions.high, units: units))  L \(WeatherService.format(conditions.low, units: units))")
                .font(NotchFont.numeric(10.5))
                .foregroundStyle(theme.tertiary)
            Spacer(minLength: 0)
            rain
        }
    }

    @ViewBuilder
    private var rain: some View {
        if let start = conditions.rainStart {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Label("Rain \(Format.countdown(to: start, from: context.date))", systemImage: "umbrella.fill")
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.cyan)
            .lineLimit(1)
        } else if conditions.isRaining {
            Label("Raining now", systemImage: "umbrella.fill")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.cyan)
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
