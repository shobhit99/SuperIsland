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
            if appState.canPresentFullExpandedModule(module) {
                content(for: module)
            } else {
                HomeScreenView()
            }
        }
    }

    @ViewBuilder
    private func content(for module: ActiveModule) -> some View {
        switch module {
        case .builtIn(.volumeHUD), .builtIn(.brightnessHUD):
            SystemHUDExpandedView()
        case .builtIn(.battery):
            BatteryExpandedView()
        case .builtIn(.shelf):
            ShelfFullExpandedView()
        case .builtIn(.calendar):
            CalendarExpandedView()
        case .builtIn(.weather):
            WeatherExpandedView()
        case .builtIn(.notifications):
            NotificationExpandedView()
        case .builtIn(.nowPlaying), .builtIn(.connectivity):
            HomeScreenView()
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
    @ObservedObject private var batteryManager = BatteryManager.shared
    @ObservedObject private var notificationManager = NotificationManager.shared

    let layout: FullExpandedTopBarLayout

    private let shoulderHorizontalPadding: CGFloat = 8
    private let shoulderTopPadding: CGFloat = 2
    private let shoulderTabSpacing: CGFloat = 8
    private let iconTabWidth: CGFloat = 36
    private let trailingControlsSlotWidth: CGFloat = 168
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
        HStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(visibleTabs) { tab in
                            FullExpandedTabButton(
                                tab: tab,
                                isSelected: tab == appState.fullExpandedSelectedTab
                            ) {
                                appState.selectFullExpandedTab(tab)
                            }
                            .id(tab.id)
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.bottom, 10)
                }
                .onChange(of: appState.fullExpandedSelectedTab) { _, newTab in
                    withAnimation(.easeInOut(duration: 0.22)) {
                        proxy.scrollTo(newTab.id, anchor: .leading)
                    }
                }
                .onChange(of: appState.currentState) { _, newState in
                    if newState == .fullExpanded {
                        proxy.scrollTo(appState.fullExpandedSelectedTab.id, anchor: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailingShoulderControls
                .padding(.bottom, 10)
        }
    }

    private var shoulderBar: some View {
        HStack(spacing: 0) {
            leadingShoulderTabs
                .frame(width: leadingShoulderWidth, alignment: .leading)

            Spacer(minLength: shoulderGapWidth)

            trailingShoulderControls
                .frame(width: trailingControlsSlotWidth, alignment: .leading)
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
                .onChange(of: appState.currentState) { _, newState in
                    if newState == .fullExpanded {
                        scrollShoulderTabs(with: proxy, animated: false)
                    }
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
                .foregroundStyle(.white.opacity(0.72))
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(islandSurfaceFill)
                        .overlay(
                            Circle()
                                .fill(Color.white.opacity(0.01))
                        )
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.035), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .hoverPointer()
        .help("Settings")
    }

    private var batteryButton: some View {
        let isSelected = appState.fullExpandedSelectedTab == .module(.builtIn(.battery))

        return Button {
            appState.selectFullExpandedTab(.module(.builtIn(.battery)))
        } label: {
            Image(systemName: batteryManager.batteryIconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(batteryButtonTint(isSelected: isSelected))
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(islandSurfaceFill)
                        .overlay(
                            Circle()
                                .fill(Color.white.opacity(isSelected ? 0.04 : 0.01))
                        )
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(isSelected ? 0.09 : 0.035), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .hoverPointer()
        .help("Battery")
    }

    private var lockButton: some View {
        let isLocked = appState.lockFullExpandedInPlace

        return Button {
            appState.toggleFullExpandedLock()
        } label: {
            Image(systemName: isLocked ? "lock.fill" : "lock.open")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(isLocked ? 0.92 : 0.72))
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(islandSurfaceFill)
                        .overlay(
                            Circle()
                                .fill(Color.white.opacity(isLocked ? 0.05 : 0.01))
                        )
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(isLocked ? 0.11 : 0.035), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .hoverPointer()
        .help(isLocked ? "Unlock island" : "Lock island open")
    }

    private var trailingShoulderControls: some View {
        HStack(spacing: 8) {
            lockButton
            batteryButton
            notificationButton
            settingsButton
        }
        .padding(.leading, settingsLeadingInset)
    }

    private var notificationButton: some View {
        let isSelected = appState.fullExpandedSelectedTab == .module(.builtIn(.notifications))

        return Button {
            appState.selectFullExpandedTab(.module(.builtIn(.notifications)))
        } label: {
            Image(systemName: "bell.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(isSelected ? 0.88 : 0.74))
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(islandSurfaceFill)
                        .overlay(
                            Circle()
                                .fill(Color.white.opacity(isSelected ? 0.04 : 0.01))
                        )
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(isSelected ? 0.09 : 0.035), lineWidth: 1)
                )
                .overlay(alignment: .topTrailing) {
                    if notificationManager.recentNotifications.isEmpty {
                        EmptyView()
                    } else {
                        notificationCountBadge
                    }
                }
        }
        .buttonStyle(.plain)
        .hoverPointer()
        .help("Notifications")
    }

    private var notificationCountBadge: some View {
        Text(notificationCountText)
            .font(.system(size: 7, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.green.opacity(0.82))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.green.opacity(0.28), lineWidth: 1)
            )
            .offset(x: 3, y: -2)
    }

    private var moduleTabs: [FullExpandedTab] {
        visibleTabs.filter { $0 != .home }
    }

    private var visibleTabs: [FullExpandedTab] {
        appState.fullExpandedTabs.filter { tab in
            if case .module(.builtIn(.notifications)) = tab {
                return false
            }
            return true
        }
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
            max(0, shoulderAvailableWidth - trailingControlsSlotWidth - settingsLeadingInset)
        )
    }

    private var leadingShoulderWidth: CGFloat {
        max(0, shoulderAvailableWidth - shoulderGapWidth - trailingControlsSlotWidth - shoulderLeadingInset)
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

    private var notificationCountText: String {
        let count = notificationManager.recentNotifications.count
        if count > 99 {
            return "99+"
        }
        return "\(count)"
    } 

    private func scrollShoulderTabs(with proxy: ScrollViewProxy, animated: Bool) {
        guard case .module(let module) = appState.fullExpandedSelectedTab else { return }
        let targetTab = FullExpandedTab.module(module)
        guard moduleTabs.contains(targetTab) else { return }
        let target = targetTab.id

        if animated {
            withAnimation(.easeInOut(duration: 0.22)) {
                proxy.scrollTo(target, anchor: .leading)
            }
        } else {
            proxy.scrollTo(target, anchor: .leading)
        }
    }

    private func batteryButtonTint(isSelected: Bool) -> Color {
        if batteryManager.isCharging {
            return Color.green.opacity(isSelected ? 0.96 : 0.84)
        }
        if batteryManager.batteryLevel <= 10 {
            return Color.red.opacity(isSelected ? 0.96 : 0.82)
        }
        if batteryManager.batteryLevel <= 20 {
            return Color.yellow.opacity(isSelected ? 0.96 : 0.82)
        }
        return Color.white.opacity(isSelected ? 0.9 : 0.74)
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
                tabIcon
                    .foregroundColor(.white.opacity(isSelected ? 0.96 : 0.72))

                if showsTitle && isSelected {
                    Text(tab.title)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                }
            }
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
        .hoverPointer()
        .help(tab.title)
    }

    @ViewBuilder
    private var tabIcon: some View {
        if let iconImage = tab.iconImage {
            Image(nsImage: iconImage)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 11, height: 11)
        } else {
            Image(systemName: tab.iconName)
                .font(.system(size: 11, weight: .semibold))
        }
    }
}
