import SwiftUI

struct WeatherExpandedView: View {
    @ObservedObject private var manager = WeatherManager.shared
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Current weather
            HStack(spacing: 12) {
                Image(systemName: manager.weather.conditionIcon)
                    .font(.system(size: 28))
                    .foregroundColor(.white)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Int(manager.weather.temperature))°")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Text(manager.weather.condition)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.7))
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("H:\(Int(manager.weather.temperatureHigh))°")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))
                    Text("L:\(Int(manager.weather.temperatureLow))°")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))
                }
            }

            // Location
            if !manager.weather.locationName.isEmpty {
                Text(manager.weather.locationName)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
            }

            // Hourly forecast (full expanded only)
            if appState.currentState == .fullExpanded && !manager.weather.hourlyForecast.isEmpty {
                Divider().background(.white.opacity(0.2))

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

                                Text("\(Int(hour.temperature))°")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                }
            }
        }
    }
}
