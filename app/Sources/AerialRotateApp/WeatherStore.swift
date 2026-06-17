import Foundation
import CoreLocation

/// The handful of sky states the dial actually draws differently. Open-Meteo's
/// fine-grained WMO weather codes collapse down into these buckets in
/// `SkyCondition(wmoCode:)`.
enum SkyCondition: Equatable {
    case unknown
    case clear
    case partlyCloudy
    case cloudy
    case fog
    case rain
    case snow
    case thunder

    /// Map an Open-Meteo `weather_code` (WMO 4677) onto a drawable bucket.
    init(wmoCode code: Int) {
        switch code {
        case 0:            self = .clear
        case 1, 2:         self = .partlyCloudy
        case 3:            self = .cloudy
        case 45, 48:       self = .fog
        case 51...67:      self = .rain          // drizzle + rain
        case 71...77:      self = .snow
        case 80...82:      self = .rain          // rain showers
        case 85, 86:       self = .snow          // snow showers
        case 95, 96, 99:   self = .thunder
        default:           self = .unknown
        }
    }
}

/// A point-in-time read of the local weather, published on `AppState` for the
/// dial to draw. `.unknown` is the cold/offline default: the dial just falls
/// back to its plain time-of-day sky with no particles.
struct WeatherSnapshot: Equatable {
    var condition: SkyCondition
    var isDay: Bool
    var temperatureC: Double?
    var place: String?
    var updatedAt: Date?

    static let unknown = WeatherSnapshot(condition: .unknown, isDay: true,
                                         temperatureC: nil, place: nil, updatedAt: nil)
}

/// Pulls live weather with zero user friction: approximate location from the
/// machine's public IP (no CoreLocation prompt, survives the app's frequent
/// ad-hoc rebuilds), then current conditions from Open-Meteo (free, no API key).
/// Polls on a slow timer and writes the result onto `AppState.shared.weather`.
/// The app isn't sandboxed, so these plain HTTPS calls need no entitlements.
final class WeatherStore {
    private var timer: Timer?
    private let session = URLSession(configuration: .ephemeral)

    /// Precise location source. When it yields a fix we use it; otherwise we fall
    /// back to the IP geolocation below. Weak: AppDelegate owns the provider.
    private weak var location: LocationProvider?

    /// Re-poll every 20 minutes. Weather drifts slowly and these are courtesy
    /// calls to free services, so there is no reason to hammer them.
    private let interval: TimeInterval = 20 * 60

    func start(location: LocationProvider? = nil) {
        self.location = location
        Task { await refresh() }
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        t.tolerance = 60          // let the OS coalesce the wake-up
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// One location + conditions round-trip. Prefer a precise CoreLocation fix;
    /// fall back to IP geolocation when location is denied or no fix arrives in
    /// time. Any failure (offline, rate-limited, shape change) leaves the
    /// previously published snapshot untouched.
    func refresh() async {
        let lat: Double, lon: Double, place: String?
        if let coord = await location?.currentCoordinate() {
            lat = coord.latitude
            lon = coord.longitude
            place = await reverseGeocode(coord)   // best-effort city label
        } else if let ip = await fetchLocation() {
            lat = ip.lat
            lon = ip.lon
            place = ip.city
        } else {
            return
        }
        guard let snap = await fetchWeather(lat: lat, lon: lon, place: place) else { return }
        await MainActor.run { AppState.shared.weather = snap }
    }

    /// Turn precise coords into a human city name for the dial label. Best-effort:
    /// nil on failure, the weather still renders without a place.
    private func reverseGeocode(_ coord: CLLocationCoordinate2D) async -> String? {
        let loc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(loc)
        return placemarks?.first?.locality
    }

    // MARK: - location (IP based)

    private struct IPLocation { let lat: Double; let lon: Double; let city: String? }

    private func fetchLocation() async -> IPLocation? {
        guard let url = URL(string: "https://ipapi.co/json/") else { return nil }
        guard let data = try? await session.data(from: url).0,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // ipapi.co signals rate-limit / failure with {"error": true, ...}.
        if obj["error"] != nil { return nil }
        guard let lat = obj["latitude"] as? Double,
              let lon = obj["longitude"] as? Double else { return nil }
        return IPLocation(lat: lat, lon: lon, city: obj["city"] as? String)
    }

    // MARK: - conditions (Open-Meteo)

    private func fetchWeather(lat: Double, lon: Double, place: String?) async -> WeatherSnapshot? {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        comps?.queryItems = [
            URLQueryItem(name: "latitude", value: String(lat)),
            URLQueryItem(name: "longitude", value: String(lon)),
            URLQueryItem(name: "current", value: "weather_code,is_day,temperature_2m"),
        ]
        guard let url = comps?.url,
              let data = try? await session.data(from: url).0,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = obj["current"] as? [String: Any],
              let code = current["weather_code"] as? Int else { return nil }
        return WeatherSnapshot(
            condition: SkyCondition(wmoCode: code),
            isDay: (current["is_day"] as? Int ?? 1) == 1,
            temperatureC: current["temperature_2m"] as? Double,
            place: place,
            updatedAt: Date())
    }
}
