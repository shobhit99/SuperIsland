import SwiftUI

struct FullExpandedView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Top drag handle
            RoundedRectangle(cornerRadius: 2)
                .fill(.white.opacity(0.3))
                .frame(width: 36, height: 4)
                .padding(.top, 8)

            // Module content
            Group {
                if let module = appState.activeModule {
                    switch module {
                    case .nowPlaying:
                        NowPlayingExpandedView()
                    case .volumeHUD, .brightnessHUD:
                        SystemHUDExpandedView()
                    case .battery:
                        BatteryExpandedView()
                    case .connectivity:
                        ConnectivityExpandedView()
                    case .calendar:
                        CalendarExpandedView()
                    case .weather:
                        WeatherExpandedView()
                    case .notifications:
                        NotificationExpandedView()
                    }
                } else {
                    defaultFullView
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 6)

            Spacer(minLength: 0)
        }
    }

    private var defaultFullView: some View {
        VStack(spacing: 12) {
            Text("DynamicIsland")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)

            Text("Swipe or click to interact")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.6))
        }
    }

    private var horizontalPadding: CGFloat {
        appState.activeModule == .nowPlaying ? 6 : 10
    }
}
