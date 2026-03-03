import SwiftUI

struct WeatherCompactView: View {
    @ObservedObject private var manager = WeatherManager.shared

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: manager.weather.conditionIcon)
                .font(.system(size: 12))
                .foregroundColor(.white)

            Text("\(Int(manager.weather.temperature))°")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
        }
    }
}
