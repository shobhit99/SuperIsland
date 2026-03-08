import SwiftUI

struct ExpandedView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if let module = appState.activeModule {
                switch module {
                case .builtIn(.nowPlaying):
                    NowPlayingExpandedView()
                case .builtIn(.volumeHUD), .builtIn(.brightnessHUD):
                    SystemHUDExpandedView()
                case .builtIn(.battery):
                    BatteryExpandedView()
                case .builtIn(.connectivity):
                    ConnectivityExpandedView()
                case .builtIn(.calendar):
                    CalendarExpandedView()
                case .builtIn(.weather):
                    WeatherExpandedView()
                case .builtIn(.notifications):
                    NotificationExpandedView()
                case .extension_(let extensionID):
                    ExtensionRendererView(extensionID: extensionID, displayMode: .expanded)
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
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var horizontalPadding: CGFloat {
        appState.activeBuiltInModule == .nowPlaying ? 4 : 8
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
