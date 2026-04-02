import SwiftUI

struct CompactView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var nowPlaying = NowPlayingManager.shared
    @ObservedObject private var battery = BatteryManager.shared

    var body: some View {
        Group {
            if appState.shouldUseMinimalCompactLayout,
               let module = appState.compactPresentationModule {
                minimalCompactContent(for: module)
            } else if appState.usesWideCompactLayout,
                      case .extension_(let extensionID) = appState.activeModule {
                WideCompactLayout(
                    leading: AnyView(ExtensionRendererView(extensionID: extensionID, displayMode: .minimalLeading)),
                    trailing: AnyView(ExtensionRendererView(extensionID: extensionID, displayMode: .minimalTrailing))
                )
            } else {
                standardCompactContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var horizontalPadding: CGFloat {
        let isNowPlayingActive = appState.activeBuiltInModule == .nowPlaying || (appState.activeModule == nil && !nowPlaying.title.isEmpty)
        let base: CGFloat = isNowPlayingActive ? 4 : 12
        // On non-notch Macs, add padding to keep content within the arch walls.
        if appState.usesWideCompactLayout {
            return base + Constants.compactCornerRadius
        }
        return base
    }

    private var standardCompactContent: some View {
        HStack(spacing: 8) {
            if let module = appState.activeModule {
                switch module {
                case .builtIn(.nowPlaying):
                    NowPlayingCompactView()
                case .builtIn(.volumeHUD), .builtIn(.brightnessHUD):
                    SystemHUDCompactView()
                case .builtIn(.battery):
                    BatteryCompactView()
                case .builtIn(.shelf):
                    ShelfCompactView()
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
                NowPlayingCompactView()
            } else {
                BatteryCompactView()
            }
        }
        .padding(.horizontal, horizontalPadding)
    }

    @ViewBuilder
    private func minimalCompactContent(for module: ActiveModule) -> some View {
        switch module {
        case .builtIn(.nowPlaying):
            MinimalCompactLayout(
                centerGapWidth: appState.compactMinimalCenterGapWidth,
                leading: AnyView(NowPlayingMinimalCompactAlbumView()),
                trailing: AnyView(NowPlayingMinimalCompactPlaybackView())
            )
        case .extension_(let extensionID):
            MinimalCompactLayout(
                centerGapWidth: appState.compactMinimalCenterGapWidth,
                leading: AnyView(ExtensionRendererView(extensionID: extensionID, displayMode: .minimalLeading)),
                trailing: AnyView(ExtensionRendererView(extensionID: extensionID, displayMode: .minimalTrailing))
            )
        default:
            standardCompactContent
        }
    }
}

/// Two-slot layout for non-notch wide compact: leading flush-left, trailing flush-right.
private struct WideCompactLayout: View {
    let leading: AnyView
    let trailing: AnyView

    var body: some View {
        HStack(spacing: 0) {
            leading
                .fixedSize()
                .padding(.leading, Constants.compactCornerRadius + 6)

            Spacer(minLength: 8)

            trailing
                .fixedSize()
                .padding(.trailing, Constants.compactCornerRadius + 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

private struct MinimalCompactLayout: View {
    let centerGapWidth: CGFloat
    let leading: AnyView
    let trailing: AnyView

    var body: some View {
        HStack(spacing: 0) {
            leading
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 6)

            Color.clear
                .frame(width: centerGapWidth)

            trailing
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, Constants.compactMinimalHorizontalPadding)
    }
}

private struct NowPlayingMinimalCompactAlbumView: View {
    @ObservedObject private var manager = NowPlayingManager.shared

    var body: some View {
        Group {
            if let art = manager.albumArt {
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(width: 26, height: 26)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}

private struct NowPlayingMinimalCompactPlaybackView: View {
    var body: some View {
        NowPlayingPlaybackCompactButton()
    }
}
