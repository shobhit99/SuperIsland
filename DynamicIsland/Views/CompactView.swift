import SwiftUI

struct CompactView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var nowPlaying = NowPlayingManager.shared
    @ObservedObject private var battery = BatteryManager.shared

    var body: some View {
        HStack(spacing: 8) {
            if let module = appState.activeModule {
                switch module {
                case .nowPlaying:
                    NowPlayingCompactView()
                case .volumeHUD, .brightnessHUD:
                    SystemHUDCompactView()
                case .battery:
                    BatteryCompactView()
                case .connectivity:
                    ConnectivityCompactView()
                case .calendar:
                    CalendarCompactView()
                case .weather:
                    WeatherCompactView()
                case .notifications:
                    NotificationCompactView()
                }
            } else if !nowPlaying.title.isEmpty {
                // Auto-show Now Playing when music is detected
                NowPlayingCompactView()
            } else {
                // Default idle: show battery + time
                BatteryCompactView()
            }
        }
        .padding(.horizontal, horizontalPadding)
    }

    private var horizontalPadding: CGFloat {
        let isNowPlayingActive = appState.activeModule == .nowPlaying || (appState.activeModule == nil && !nowPlaying.title.isEmpty)
        return isNowPlayingActive ? 4 : 12
    }
}
