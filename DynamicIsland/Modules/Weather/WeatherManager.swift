import Foundation
import CoreLocation
import Combine

struct WeatherData {
    var temperature: Double = 0
    var temperatureHigh: Double = 0
    var temperatureLow: Double = 0
    var condition: String = "Clear"
    var conditionIcon: String = "sun.max.fill"
    var locationName: String = ""
    var hourlyForecast: [HourlyWeather] = []
}

struct HourlyWeather: Identifiable {
    let id = UUID()
    let hour: String
    let temperature: Double
    let conditionIcon: String
}

final class WeatherManager: NSObject, ObservableObject {
    static let shared = WeatherManager()

    @Published var weather = WeatherData()
    @Published var isLoading = false

    private let locationManager = CLLocationManager()
    private var lastFetchTime: Date?
    private var refreshTimer: Timer?

    override private init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
        requestLocationAndFetch()
        startRefreshTimer()
    }

    // MARK: - Location

    func requestLocationAndFetch() {
        locationManager.requestWhenInUseAuthorization()
        locationManager.requestLocation()
    }

    // MARK: - Fetching (Open-Meteo free API)

    func fetchWeather(latitude: Double, longitude: Double) {
        guard !isLoading else { return }

        // Debounce: don't fetch more than once per 5 minutes
        if let lastFetch = lastFetchTime, Date().timeIntervalSince(lastFetch) < 300 {
            return
        }

        isLoading = true

        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(latitude)&longitude=\(longitude)&current=temperature_2m,weather_code&hourly=temperature_2m,weather_code&daily=temperature_2m_max,temperature_2m_min&temperature_unit=fahrenheit&timezone=auto&forecast_days=1"

        guard let url = URL(string: urlString) else {
            isLoading = false
            return
        }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            defer { DispatchQueue.main.async { self?.isLoading = false } }

            guard let data, error == nil else { return }

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    DispatchQueue.main.async {
                        self?.parseWeatherResponse(json)
                        self?.lastFetchTime = Date()
                    }
                }
            } catch {
                print("Weather parse error: \(error)")
            }
        }.resume()

        // Reverse geocode for location name
        let location = CLLocation(latitude: latitude, longitude: longitude)
        CLGeocoder().reverseGeocodeLocation(location) { [weak self] placemarks, _ in
            if let city = placemarks?.first?.locality {
                DispatchQueue.main.async {
                    self?.weather.locationName = city
                }
            }
        }
    }

    // MARK: - Parsing

    private func parseWeatherResponse(_ json: [String: Any]) {
        // Current weather
        if let current = json["current"] as? [String: Any] {
            if let temp = current["temperature_2m"] as? Double {
                weather.temperature = temp
            }
            if let code = current["weather_code"] as? Int {
                weather.condition = conditionName(for: code)
                weather.conditionIcon = conditionIcon(for: code)
            }
        }

        // Daily high/low
        if let daily = json["daily"] as? [String: Any] {
            if let maxTemps = daily["temperature_2m_max"] as? [Double], let first = maxTemps.first {
                weather.temperatureHigh = first
            }
            if let minTemps = daily["temperature_2m_min"] as? [Double], let first = minTemps.first {
                weather.temperatureLow = first
            }
        }

        // Hourly forecast (next 6 hours)
        if let hourly = json["hourly"] as? [String: Any],
           let times = hourly["time"] as? [String],
           let temps = hourly["temperature_2m"] as? [Double],
           let codes = hourly["weather_code"] as? [Int] {

            let calendar = Foundation.Calendar.current
            let currentHour = calendar.component(.hour, from: Date())
            let startIndex = max(currentHour, 0)
            let endIndex = min(startIndex + 6, times.count)

            var forecast: [HourlyWeather] = []
            for i in startIndex..<endIndex {
                let hourStr: String
                if i == currentHour {
                    hourStr = "Now"
                } else {
                    let hour = i % 24
                    hourStr = hour == 0 ? "12 AM" : (hour <= 12 ? "\(hour) \(hour < 12 ? "AM" : "PM")" : "\(hour - 12) PM")
                }

                forecast.append(HourlyWeather(
                    hour: hourStr,
                    temperature: temps[i],
                    conditionIcon: conditionIcon(for: codes[i])
                ))
            }
            weather.hourlyForecast = forecast
        }
    }

    // MARK: - WMO Weather Code Mapping

    private func conditionName(for code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1, 2, 3: return "Partly Cloudy"
        case 45, 48: return "Foggy"
        case 51, 53, 55: return "Drizzle"
        case 61, 63, 65: return "Rain"
        case 66, 67: return "Freezing Rain"
        case 71, 73, 75: return "Snow"
        case 77: return "Snow Grains"
        case 80, 81, 82: return "Showers"
        case 85, 86: return "Snow Showers"
        case 95: return "Thunderstorm"
        case 96, 99: return "Hailstorm"
        default: return "Clear"
        }
    }

    private func conditionIcon(for code: Int) -> String {
        switch code {
        case 0: return "sun.max.fill"
        case 1, 2: return "cloud.sun.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55: return "cloud.drizzle.fill"
        case 61, 63, 65: return "cloud.rain.fill"
        case 66, 67: return "cloud.sleet.fill"
        case 71, 73, 75, 77: return "cloud.snow.fill"
        case 80, 81, 82: return "cloud.heavyrain.fill"
        case 85, 86: return "cloud.snow.fill"
        case 95, 96, 99: return "cloud.bolt.fill"
        default: return "sun.max.fill"
        }
    }

    // MARK: - Refresh

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: Constants.weatherRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            self?.requestLocationAndFetch()
        }
    }

    deinit {
        refreshTimer?.invalidate()
    }
}

// MARK: - CLLocationManagerDelegate

extension WeatherManager: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        fetchWeather(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error: \(error)")
    }
}
