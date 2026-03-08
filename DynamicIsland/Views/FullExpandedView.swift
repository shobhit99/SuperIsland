import SwiftUI

struct FullExpandedView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
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
                        ExtensionRendererView(extensionID: extensionID, displayMode: .fullExpanded)
                    }
                } else {
                    defaultFullView
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
        switch appState.activeModule {
        case .extension_:
            return 4
        case .builtIn(.nowPlaying):
            return 6
        default:
            return 10
        }
    }
}
