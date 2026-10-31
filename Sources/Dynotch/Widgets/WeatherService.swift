import AppKit
import Combine
import CoreLocation

/// Current conditions, today's high and low, and rain on the way, from Open-Meteo, which needs no
/// key. The place is a city picked in Settings or, if the user allows it, where the Mac is.
@MainActor
final class WeatherService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = WeatherService()

    struct Conditions: Equatable {
        /// Degrees Celsius.
        var temperature: Double
        var high: Double
        var low: Double
        /// A WMO weather code.
        var code: Int
        var isDay: Bool
        var isRaining: Bool
        /// When rain should start, if it's due within the hour and it isn't raining yet.
        var rainStart: Date?
        /// 2.5 mm or more in a quarter of an hour.
        var isHeavyRain: Bool
    }

    /// A city from Open-Meteo's geocoding search.
    struct Place: Identifiable, Equatable, Decodable {
        let id: Int
        let name: String
        let latitude: Double
        let longitude: Double
        let country: String?
        let admin1: String?

        /// "Illinois, United States"
        var region: String {
            [admin1, country].compactMap { $0 }.filter { $0 != name }.joined(separator: ", ")
        }
    }

    enum Status: Equatable {
        case needsPlace, locating, locationOff, loading, ready, failed
    }

    @Published private(set) var conditions: Conditions?
    @Published private(set) var status = Status.needsPlace
    /// The city the weather is for.
    @Published private(set) var placeName = ""
    @Published private(set) var locationAccess: CLAuthorizationStatus

    private let locationManager = CLLocationManager()
    private var location: CLLocation?
    /// The town Location Services put the Mac in.
    private var locationName = ""
    /// "here", or the city: when it changes, the old conditions go.
    private var source = ""
    private var poll: Poll?
    private var refreshTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    /// When the rain we last announced was due. Cleared once it's dry again.
    private var announcedRain: Date?

    private override init() {
        locationAccess = locationManager.authorizationStatus
        super.init()
    }

    func start() {
        locationManager.delegate = self
        let settings = AppSettings.shared
        Publishers.Merge3(settings.$weatherPlace.map { _ in () }, settings.$weatherUsesLocation.map { _ in () },
                          settings.$weatherLatitude.map { _ in () })
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &cancellables)
        // Also when someone's back after the Mac or its displays slept, if one came due meanwhile.
        poll = EnergyCoordinator.shared.schedule(.weather) { [weak self] in self?.refresh() }
    }

    func refresh() {
        let settings = AppSettings.shared
        let source = settings.weatherUsesLocation ? "here" : settings.weatherPlace
        if source != self.source {
            self.source = source
            refreshTask?.cancel()
            conditions = nil
            announcedRain = nil
        }
        if settings.weatherUsesLocation {
            placeName = locationName
            guard isLocationAllowed else {
                status = locationAccess == .notDetermined ? .locating : .locationOff
                if locationAccess == .notDetermined { locationManager.requestWhenInUseAuthorization() }
                return
            }
            // The Mac rarely moves far; a fix from the last half hour will do.
            guard let location, location.timestamp.timeIntervalSinceNow > -30 * 60 else {
                if conditions == nil { status = .locating }
                locationManager.requestLocation()
                return
            }
            load(location.coordinate)
        } else if !settings.weatherPlace.isEmpty {
            placeName = settings.weatherPlace.components(separatedBy: ",").first ?? settings.weatherPlace
            load(CLLocationCoordinate2D(latitude: settings.weatherLatitude, longitude: settings.weatherLongitude))
        } else {
            placeName = ""
            status = .needsPlace
        }
    }

    // MARK: Place

    /// Asks for Location Services, or opens System Settings if it was turned down before.
    func requestLocationAccess() {
        switch locationAccess {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            CalendarService.openPrivacySettings("Privacy_LocationServices")
        default:
            locationManager.requestLocation()
        }
    }

    /// On the Mac, "while using" access reports as authorizedAlways.
    var isLocationAllowed: Bool {
        locationAccess == .authorizedAlways
    }

    func choose(_ place: Place) {
        let settings = AppSettings.shared
        settings.weatherLatitude = place.latitude
        settings.weatherLongitude = place.longitude
        settings.weatherPlace = place.region.isEmpty ? place.name : "\(place.name), \(place.region)"
        settings.weatherUsesLocation = false
    }

    /// Cities matching `query`, from Open-Meteo's geocoding API.
    nonisolated static func search(_ query: String) async -> [Place] {
        struct Response: Decodable { let results: [Place]? }
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "name", value: query),
            URLQueryItem(name: "count", value: "6"),
            URLQueryItem(name: "language", value: String(Locale.preferredLanguages.first?.prefix(2) ?? "en")),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components.url, let (data, _) = try? await URLSession.shared.data(from: url) else { return [] }
        return (try? JSONDecoder().decode(Response.self, from: data))?.results ?? []
    }

    // MARK: Units

    /// "18°", in the unit picked in Settings or the system's.
    static func format(_ celsius: Double, units: TemperatureUnits) -> String {
        let fahrenheit = units == .fahrenheit || (units == .system && systemUsesFahrenheit)
        let value = fahrenheit ? celsius * 9 / 5 + 32 : celsius
        return "\(Int(value.rounded()))°"
    }

    /// The region's unit, or the one chosen under Temperature in Language & Region. The weather
    /// formatter knows both.
    static var systemUsesFahrenheit: Bool {
        Measurement(value: 0, unit: UnitTemperature.celsius).formatted(.measurement(width: .narrow, usage: .weather))
            .contains("32")
    }

    // MARK: Location Services

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            locationAccess = manager.authorizationStatus
            if AppSettings.shared.weatherUsesLocation { refresh() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            guard let latest = locations.last else { return }
            let moved = location.map { $0.distance(from: latest) > 2_000 } ?? true
            location = latest
            if moved { name(latest) }
            if AppSettings.shared.weatherUsesLocation { load(latest.coordinate) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            if conditions == nil, AppSettings.shared.weatherUsesLocation { status = .failed }
        }
    }

    /// The town the Mac is in, for the widget's header. The location itself is never stored.
    private func name(_ location: CLLocation) {
        Task {
            let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first
            locationName = placemark?.locality ?? placemark?.name ?? "Current location"
            if AppSettings.shared.weatherUsesLocation { placeName = locationName }
        }
    }

    // MARK: Forecast

    private func load(_ coordinate: CLLocationCoordinate2D) {
        if conditions == nil { status = .loading }
        refreshTask?.cancel()
        refreshTask = Task {
            do {
                let conditions = try await Self.fetch(coordinate)
                guard !Task.isCancelled else { return }
                self.conditions = conditions
                status = .ready
                announceRain(conditions)
            } catch {
                guard !Task.isCancelled else { return }
                if conditions == nil { status = .failed }
            }
        }
    }

    /// Posts a heads-up in the closed notch once rain is half an hour away, once per shower.
    private func announceRain(_ conditions: Conditions) {
        guard let start = conditions.rainStart else {
            if !conditions.isRaining { announcedRain = nil }
            return
        }
        guard AppSettings.shared.rainAlerts, announcedRain == nil, start.timeIntervalSinceNow <= 30 * 60 else { return }
        announcedRain = start
        let snow = conditions.temperature <= 0
        let kind = snow ? "Snow" : conditions.isHeavyRain ? "Heavy rain" : "Rain"
        LiveActivityCenter.shared.post(LiveNotice(key: "rain", symbol: snow ? "cloud.snow.fill" : "cloud.rain.fill",
                                                  tint: .cyan, text: Format.countdown(to: start),
                                                  detail: "\(kind) starting soon", timing: .perishes), for: 6)
    }

    /// Open-Meteo's forecast for the next hour or two. Coordinates are rounded to about a kilometer.
    nonisolated static func fetch(_ coordinate: CLLocationCoordinate2D) async throws -> Conditions {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.2f", coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.2f", coordinate.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day,precipitation"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "minutely_15", value: "precipitation"),
            URLQueryItem(name: "forecast_minutely_15", value: "8"),
            URLQueryItem(name: "hourly", value: "precipitation"),
            URLQueryItem(name: "forecast_hours", value: "3"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "1"),
        ]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Forecast.self, from: data).conditions(now: .now)
    }

    // MARK: Snapshots

    func loadSample(place: String, conditions: Conditions?) {
        placeName = place
        self.conditions = conditions
        status = conditions == nil ? .needsPlace : .ready
    }
}

/// The parts of Open-Meteo's forecast response the widget uses. The keys are spelled out:
/// `convertFromSnakeCase` would turn "temperature_2m" into "temperature2M".
struct Forecast: Decodable {
    struct Current: Decodable {
        let time: TimeInterval
        let temperature: Double
        let weatherCode: Int
        let isDay: Int
        let precipitation: Double?

        enum CodingKeys: String, CodingKey {
            case time, precipitation
            case temperature = "temperature_2m"
            case weatherCode = "weather_code"
            case isDay = "is_day"
        }
    }

    struct Daily: Decodable {
        let high: [Double?]
        let low: [Double?]

        enum CodingKeys: String, CodingKey {
            case high = "temperature_2m_max"
            case low = "temperature_2m_min"
        }
    }

    /// Times (Unix seconds) and the precipitation in the period starting at each, in millimeters.
    struct Series: Decodable {
        let time: [TimeInterval]
        let precipitation: [Double?]
    }

    let current: Current
    let daily: Daily
    let minutely15: Series?
    let hourly: Series?

    enum CodingKeys: String, CodingKey {
        case current, daily, hourly
        case minutely15 = "minutely_15"
    }

    func conditions(now: Date) -> WeatherService.Conditions {
        let rain = rain(now: now.timeIntervalSince1970)
        return WeatherService.Conditions(temperature: current.temperature,
                                         high: daily.high.first.flatMap { $0 } ?? current.temperature,
                                         low: daily.low.first.flatMap { $0 } ?? current.temperature,
                                         code: current.weatherCode, isDay: current.isDay == 1,
                                         isRaining: rain.isRaining, rainStart: rain.start.map(Date.init(timeIntervalSince1970:)),
                                         isHeavyRain: rain.isHeavy)
    }

    /// Whether it's raining now and when it starts if not, within the hour. Uses the 15-minute
    /// forecast where Open-Meteo has one, and the hourly one otherwise.
    func rain(now: TimeInterval) -> (isRaining: Bool, start: TimeInterval?, isHeavy: Bool) {
        let (slots, length, threshold): ([(time: TimeInterval, amount: Double)], TimeInterval, Double) = {
            let quarters = Self.slots(minutely15)
            return quarters.isEmpty ? (Self.slots(hourly), 3600, 0.2) : (quarters, 900, 0.1)
        }()
        let wetNow = (current.precipitation ?? 0) >= 0.1
            || slots.contains { $0.time <= now && now < $0.time + length && $0.amount >= threshold }
        if wetNow { return (true, nil, false) }
        guard let next = slots.first(where: { $0.time > now && $0.time <= now + 3600 && $0.amount >= threshold }) else {
            return (false, nil, false)
        }
        return (false, next.time, next.amount * 900 / length >= 2.5)
    }

    private static func slots(_ series: Series?) -> [(time: TimeInterval, amount: Double)] {
        guard let series else { return [] }
        return zip(series.time, series.precipitation).compactMap { time, amount in amount.map { (time, $0) } }
    }
}
