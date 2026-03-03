import SwiftUI

struct ExpandedView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
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
                // Default expanded view - show quick summary
                HStack(spacing: 16) {
                    ModuleSummaryItem(icon: "battery.100", label: "Battery")
                    ModuleSummaryItem(icon: "music.note", label: "Music")
                    ModuleSummaryItem(icon: "calendar", label: "Calendar")
                }
                .foregroundColor(.white)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 6)
    }

    private var horizontalPadding: CGFloat {
        appState.activeModule == .nowPlaying ? 4 : 8
    }
}

struct ModuleSummaryItem: View {
    let icon: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 18))
            Text(label)
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundColor(.white.opacity(0.7))
    }
}
