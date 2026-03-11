import SwiftUI

struct FullExpandedView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            if !appState.hasFullExpandedShoulderBarSpace {
                FullExpandedTopBarView(layout: .inline)
                    .environmentObject(appState)
                    .padding(.bottom, 8)
            }

            currentTabContent
                .padding(.horizontal, contentHorizontalPadding)
                .padding(.bottom, contentBottomPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var currentTabContent: some View {
        switch appState.fullExpandedSelectedTab {
        case .home:
            HomeScreenView()
        case .module(let module):
            content(for: module)
        }
    }

    @ViewBuilder
    private func content(for module: ActiveModule) -> some View {
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
    }

    private var contentHorizontalPadding: CGFloat {
        switch appState.fullExpandedSelectedTab {
        case .home:
            return 0
        case .module(.extension_):
            return 2
        case .module(.builtIn(.nowPlaying)):
            return 4
        default:
            return 8
        }
    }

    private var contentBottomPadding: CGFloat {
        switch appState.fullExpandedSelectedTab {
        case .home:
            return 0
        case .module(.extension_):
            return 2
        default:
            return 4
        }
    }
}

enum FullExpandedTopBarLayout {
    case inline
    case shoulder
}

struct FullExpandedTopBarView: View {
    @EnvironmentObject private var appState: AppState

    let layout: FullExpandedTopBarLayout

    private let shoulderHorizontalPadding: CGFloat = 8
    private let shoulderTopPadding: CGFloat = 2
    private let shoulderTabSpacing: CGFloat = 8
    private let iconTabWidth: CGFloat = 34
    private let settingsButtonSlotWidth: CGFloat = 52
    private let shoulderLeadingInset: CGFloat = 24
    private let settingsLeadingInset: CGFloat = 4

    var body: some View {
        Group {
            if layout == .shoulder {
                shoulderBar
            } else {
                inlineBar
            }
        }
    }

    private var inlineBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(appState.fullExpandedTabs) { tab in
                    FullExpandedTabButton(
                        tab: tab,
                        isSelected: tab == appState.fullExpandedSelectedTab
                    ) {
                        appState.selectFullExpandedTab(tab)
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 10)
        }
    }

    private var shoulderBar: some View {
        HStack(spacing: 0) {
            leadingShoulderTabs
                .frame(width: leadingShoulderWidth, alignment: .leading)

            Spacer(minLength: shoulderGapWidth)

            settingsButton
                .frame(width: settingsButtonSlotWidth, alignment: .leading)
        }
        .frame(width: shoulderAvailableWidth, alignment: .top)
        .padding(.horizontal, shoulderHorizontalPadding)
        .padding(.top, shoulderTopPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
    }

    private var leadingShoulderTabs: some View {
        HStack(spacing: shoulderTabSpacing) {
            FullExpandedTabButton(
                tab: .home,
                isSelected: appState.fullExpandedSelectedTab == .home,
                showsTitle: false
            ) {
                appState.selectFullExpandedTab(.home)
            }
            .frame(width: iconTabWidth)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: shoulderTabSpacing) {
                        ForEach(moduleTabs) { tab in
                            FullExpandedTabButton(
                                tab: tab,
                                isSelected: tab == appState.fullExpandedSelectedTab,
                                showsTitle: false
                            ) {
                                appState.selectFullExpandedTab(tab)
                            }
                            .frame(width: iconTabWidth)
                            .id(tab.id)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .frame(width: shoulderModuleViewportWidth, alignment: .leading)
                .clipped()
                .onAppear {
                    scrollShoulderTabs(with: proxy, animated: false)
                }
                .onChange(of: appState.fullExpandedSelectedTab) { _, _ in
                    scrollShoulderTabs(with: proxy, animated: true)
                }
            }
        }
        .frame(width: leadingShoulderWidth, alignment: .leading)
        .padding(.leading, shoulderLeadingInset)
        .clipped()
    }

    private var settingsButton: some View {
        Button {
            AppDelegate.showSettingsWindow()
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(islandSurfaceFill)
                        .overlay(
                            Circle()
                                .fill(Color.white.opacity(0.05))
                        )
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help("Settings")
        .padding(.leading, settingsLeadingInset)
    }

    private var moduleTabs: [FullExpandedTab] {
        appState.fullExpandedTabs.filter { $0 != .home }
    }

    private var shoulderModuleViewportWidth: CGFloat {
        let visibleModuleCount: CGFloat = 3
        let contentWidth = (iconTabWidth * visibleModuleCount) + (shoulderTabSpacing * max(0, visibleModuleCount - 1)) + 4
        return min(leadingScrollableWidth, contentWidth)
    }

    private var shoulderAvailableWidth: CGFloat {
        max(0, appState.currentContentSize.width - (shoulderHorizontalPadding * 2))
    }

    private var shoulderGapWidth: CGFloat {
        min(
            appState.fullExpandedShoulderGapWidth,
            max(0, shoulderAvailableWidth - settingsButtonSlotWidth - settingsLeadingInset)
        )
    }

    private var leadingShoulderWidth: CGFloat {
        max(0, shoulderAvailableWidth - shoulderGapWidth - settingsButtonSlotWidth - shoulderLeadingInset)
    }

    private var leadingScrollableWidth: CGFloat {
        max(0, leadingShoulderWidth - iconTabWidth - shoulderTabSpacing)
    }

    private var islandSurfaceFill: LinearGradient {
        LinearGradient(
            colors: [
                Color.black.opacity(0.98),
                Color.black.opacity(0.94)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func scrollShoulderTabs(with proxy: ScrollViewProxy, animated: Bool) {
        guard case .module(let module) = appState.fullExpandedSelectedTab else { return }
        let target = FullExpandedTab.module(module).id

        if animated {
            withAnimation(.easeInOut(duration: 0.22)) {
                proxy.scrollTo(target, anchor: .leading)
            }
        } else {
            proxy.scrollTo(target, anchor: .leading)
        }
    }
}

private struct FullExpandedTabButton: View {
    let tab: FullExpandedTab
    let isSelected: Bool
    var showsTitle: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: tab.iconName)
                    .font(.system(size: 11, weight: .semibold))

                if showsTitle && isSelected {
                    Text(tab.title)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                }
            }
            .foregroundColor(.white.opacity(isSelected ? 0.96 : 0.72))
            .padding(.horizontal, showsTitle && isSelected ? 11 : 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.black.opacity(0.98),
                                Color.black.opacity(0.94)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(isSelected ? 0.05 : 0.02))
                    )
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(isSelected ? 0.12 : 0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(tab.title)
    }
}
