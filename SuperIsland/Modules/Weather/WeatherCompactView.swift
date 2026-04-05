import SwiftUI

struct WeatherCompactView: View {
    @ObservedObject private var manager = WeatherManager.shared
    @ObservedObject private var appState = AppState.shared

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: manager.weather.conditionIcon)
                .font(.system(size: 12))
                .foregroundColor(.white)

            Text(formattedTemp(manager.weather.temperature))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
        }
    }

    private func formattedTemp(_ celsius: Double) -> String {
        switch appState.temperatureUnit {
        case .celsius:
            return "\(Int(celsius.rounded()))°C"
        case .fahrenheit:
            return "\(Int((celsius * 9 / 5 + 32).rounded()))°F"
        }
    }
}
