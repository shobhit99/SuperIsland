import SwiftUI

struct CompactView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var nowPlaying = NowPlayingManager.shared
    @ObservedObject private var battery = BatteryManager.shared

    var body: some View {
        HStack(spacing: 8) {
            if let module = appState.activeModule {
                switch module {
                case .builtIn(.nowPlaying):
                    NowPlayingCompactView()
                case .builtIn(.volumeHUD), .builtIn(.brightnessHUD):
                    SystemHUDCompactView()
                case .builtIn(.battery):
                    BatteryCompactView()
                case .builtIn(.connectivity):
                    ConnectivityCompactView()
                case .builtIn(.calendar):
                    CalendarCompactView()
                case .builtIn(.weather):
                    WeatherCompactView()
                case .builtIn(.notifications):
                    NotificationCompactView()
                case .extension_(let extensionID):
                    ExtensionRendererView(extensionID: extensionID, displayMode: .compact)
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
        let isNowPlayingActive = appState.activeBuiltInModule == .nowPlaying || (appState.activeModule == nil && !nowPlaying.title.isEmpty)
        return isNowPlayingActive ? 4 : 12
    }
}
