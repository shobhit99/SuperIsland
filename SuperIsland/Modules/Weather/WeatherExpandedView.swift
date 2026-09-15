import SwiftUI

struct WeatherExpandedView: View {
    @ObservedObject private var manager = WeatherManager.shared
    @EnvironmentObject var appState: AppState

    private func temp(_ celsius: Double) -> String {
        switch appState.temperatureUnit {
        case .celsius:    return "\(Int(celsius.rounded()))°C"
        case .fahrenheit: return "\(Int((celsius * 9 / 5 + 32).rounded()))°F"
        }
    }

    // Degree-only variant so a daily high/low pair fits a forecast cell.
    private func shortTemp(_ celsius: Double) -> String {
        switch appState.temperatureUnit {
        case .celsius:    return "\(Int(celsius.rounded()))°"
        case .fahrenheit: return "\(Int((celsius * 9 / 5 + 32).rounded()))°"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Current weather — with the multi-day forecast alongside,
            // visually separated from today's block.
            HStack(spacing: 12) {
                Image(systemName: manager.weather.conditionIcon)
                    .font(.system(size: 28))
                    .foregroundColor(.white)

                VStack(alignment: .leading, spacing: 2) {
                    Text(temp(manager.weather.temperature))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Text(manager.weather.condition)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.7))
                }

                VStack(alignment: .trailing, spacing: 2) {
                    Text("H:\(temp(manager.weather.temperatureHigh))")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))
                    Text("L:\(temp(manager.weather.temperatureLow))")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))
                }

                if appState.currentState == .fullExpanded, !manager.weather.dailyForecast.isEmpty {
                    Rectangle()
                        .fill(.white.opacity(0.18))
                        .frame(width: 1, height: 40)
                        .padding(.horizontal, 4)

                    HStack(spacing: 14) {
                        ForEach(manager.weather.dailyForecast) { day in
                            VStack(spacing: 3) {
                                Text(day.dayLabel)
                                    .font(.system(size: 10))
                                    .foregroundColor(.white.opacity(0.6))

                                Image(systemName: day.conditionIcon)
                                    .font(.system(size: 13))
                                    .foregroundColor(.white)

                                HStack(spacing: 3) {
                                    Text(shortTemp(day.high))
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(.white)
                                    Text(shortTemp(day.low))
                                        .font(.system(size: 10))
                                        .foregroundColor(.white.opacity(0.5))
                                }
                            }
                        }
                    }
                }

                Spacer()
            }

            // Location
            if !manager.weather.locationName.isEmpty {
                Text(manager.weather.locationName)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
            }

            if appState.currentState == .fullExpanded {
                Divider().background(.white.opacity(0.2))

                // Hourly forecast + details side by side
                HStack(alignment: .top, spacing: 0) {
                    // Hourly forecast (left)
                    if !manager.weather.hourlyForecast.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                ForEach(manager.weather.hourlyForecast) { hour in
                                    VStack(spacing: 4) {
                                        Text(hour.hour)
                                            .font(.system(size: 10))
                                            .foregroundColor(.white.opacity(0.6))

                                        Image(systemName: hour.conditionIcon)
                                            .font(.system(size: 14))
                                            .foregroundColor(.white)

                                        Text(temp(hour.temperature))
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundColor(.white)
                                    }
                                }
                            }
                        }
                    }

                    Spacer(minLength: 16)

                    // Weather details grid (right)
                    weatherDetailsGrid
                }
            }
        }
    }

    private var weatherDetailsGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                weatherDetailCell(icon: "thermometer.medium", title: "Feels Like", value: temp(manager.weather.feelsLike))
                weatherDetailCell(icon: "humidity.fill", title: "Humidity", value: "\(manager.weather.humidity)%")
                weatherDetailCell(icon: "aqi.medium", title: "AQI", value: aqiLabel)
            }
            HStack(spacing: 16) {
                weatherDetailCell(icon: "wind", title: "Wind", value: "\(Int(manager.weather.windSpeed)) mph")
                weatherDetailCell(icon: "sun.max.trianglebadge.exclamationmark.fill", title: "UV Index", value: uvLabel)
                Spacer()
            }
        }
    }

    private func weatherDetailCell(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.45))
                .frame(width: 16, alignment: .center)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
                Text(value)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
            }
        }
    }

    private var uvLabel: String {
        let uv = manager.weather.uvIndex
        let level: String
        switch uv {
        case ..<3: level = "Low"
        case ..<6: level = "Mod"
        case ..<8: level = "High"
        case ..<11: level = "Very High"
        default: level = "Extreme"
        }
        return "\(Int(uv)) \(level)"
    }

    private var aqiLabel: String {
        let aqi = manager.weather.aqi
        if aqi == 0 { return "—" }
        let level: String
        switch aqi {
        case ..<51: level = "Good"
        case ..<101: level = "Moderate"
        case ..<151: level = "Unhealthy*"
        case ..<201: level = "Unhealthy"
        case ..<301: level = "Very Poor"
        default: level = "Hazardous"
        }
        return "\(aqi) \(level)"
    }
}
