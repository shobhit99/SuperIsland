import SwiftUI

struct IslandContainerView: View {
    @EnvironmentObject var appState: AppState
    @State private var isHoveringIslandSurface = false
    @State private var isHoveringPreviousButton = false
    @State private var isHoveringNextButton = false
    @State private var isShelfDropTargeted = false
    @State private var shelfDragEndWorkItem: DispatchWorkItem?
    private let hoverValidationTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        // No GeometryReader — just like NotchDrop. The surface sizes
        // itself from appState. Transparent areas around the surface
        // are truly empty (alpha=0), so macOS passes clicks through.
        ZStack(alignment: .top) {
            islandSurface

            if showModuleCycler {
                moduleCyclerOverlay
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: isShelfDropTargeted) { _, isTargeted in
            handleShelfDropTargetChange(isTargeted)
        }
        .onChange(of: showModuleCycler) { _, isVisible in
            guard !isVisible else { return }
            setCycleButtonHover(false, forward: false)
            setCycleButtonHover(false, forward: true)
        }
        .onReceive(hoverValidationTimer) { _ in
            validateHoverState()
        }
    }

    // MARK: - Surface

    private var islandSurface: some View {
        let surfaceSize = appState.currentSize
        return ZStack(alignment: .top) {
            islandShape
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

            islandContent
                .frame(width: surfaceSize.width, height: surfaceSize.height, alignment: .top)
        }
        .frame(width: surfaceSize.width, height: surfaceSize.height)
        .clipShape(islandShape)
        .compositingGroup()
        .shadow(
            color: .black.opacity(ambientShadowOpacity),
            radius: ambientShadowRadius,
            y: ambientShadowYOffset
        )
        .shadow(
            color: .black.opacity(keyShadowOpacity),
            radius: keyShadowRadius,
            y: keyShadowYOffset
        )
        .overlay {
            if appState.shelfEnabled && isShelfDropTargeted {
                islandShape
                    .stroke(Color.accentColor.opacity(0.92), style: StrokeStyle(lineWidth: 3, dash: [10]))
                    .padding(1)
            }
        }
        .contentShape(islandShape)
        .modifier(IslandSurfaceSwipeModifier(
            enabled: appState.islandSurfaceSwipeEnabled,
            isCompact: appState.currentState == .compact,
            onTrackpad: { handleHorizontalSwipe($0) },
            onDragEnded: { handleSwipe(value: $0) }
        ))
        .onContinuousHover(coordinateSpace: .local) { phase in
            handleSurfaceHover(phase: phase, surfaceSize: surfaceSize)
        }
        .onTapGesture {
            handleSurfaceTap()
        }
        .gesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in
                    AppDelegate.showSettingsWindow()
                }
        )
        .onDrop(of: ShelfStore.acceptedDropTypes, isTargeted: $isShelfDropTargeted) { providers in
            guard appState.shelfEnabled else { return false }
            return ShelfStore.shared.handleDrop(providers: providers) { addedCount in
                guard addedCount > 0 else { return }
                shelfDragEndWorkItem?.cancel()
                shelfDragEndWorkItem = nil
                appState.presentShelfAfterDrop()
            }
        }
        .animation(.spring(response: 0.48, dampingFraction: 0.8), value: appState.activeModule)
    }

    // MARK: - Content

    @ViewBuilder
    private var islandContent: some View {
        if appState.currentState == .compact {
            CompactView()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .opacity(compactContentOpacity)
                .transition(
                    .scale(scale: 0.85, anchor: .top)
                    .combined(with: .opacity)
                )
        } else {
            expandedIslandLayout
                .opacity(compactContentOpacity)
                .transition(
                    .scale(scale: 0.5, anchor: .top)
                    .combined(with: .opacity)
                )
        }
    }

    // MARK: - Shape

    private var islandShape: PillShape {
        PillShape(
            topLeadingRadius: appState.currentTopLeadingCornerRadius,
            topTrailingRadius: appState.currentTopTrailingCornerRadius,
            bottomLeadingRadius: appState.currentBottomLeadingCornerRadius,
            bottomTrailingRadius: appState.currentBottomTrailingCornerRadius,
            outwardTopCorners: appState.usesOutwardTopCorners,
            topCutoutWidth: appState.currentTopCutoutWidth,
            topCutoutDepth: appState.currentTopCutoutDepth,
            topCutoutCornerRadius: appState.currentTopCutoutCornerRadius
        )
    }

    // MARK: - Appearance

    private var compactContentOpacity: Double {
        1.0
    }

    // Shadows are intentionally disabled in the compact state. The island
    // panel is non-activating and sits in the transparent region around the
    // notch — any non-zero shadow pixel in that transparent region gets
    // captured by the panel's hit test and blocks clicks from reaching apps
    // underneath (see issue #1).
    private var ambientShadowOpacity: Double {
        appState.currentState == .compact ? 0.0 : 0.38
    }

    private var ambientShadowRadius: CGFloat {
        appState.currentState == .compact ? 0 : 8
    }

    private var ambientShadowYOffset: CGFloat {
        appState.currentState == .compact ? 0 : 6
    }

    private var keyShadowOpacity: Double {
        appState.currentState == .compact ? 0.0 : 0.58
    }

    private var keyShadowRadius: CGFloat {
        appState.currentState == .compact ? 0 : 14
    }

    private var keyShadowYOffset: CGFloat {
        appState.currentState == .compact ? 0 : 10
    }

    // MARK: - Expanded Layout

    private var expandedIslandLayout: some View {
        let surfaceSize = appState.currentSize
        let shoulderHeight = min(appState.currentContentTopInset, surfaceSize.height)
        let contentWidth = min(appState.currentContentSize.width, surfaceSize.width)
        let contentHeight = max(0, surfaceSize.height - shoulderHeight)

        return VStack(spacing: 0) {
            if appState.hasFullExpandedShoulderBarSpace {
                FullExpandedTopBarView(layout: .shoulder)
                    .environmentObject(appState)
                    .frame(
                        width: contentWidth,
                        height: shoulderHeight,
                        alignment: .top
                    )
            } else {
                Color.clear
                    .frame(height: shoulderHeight)
            }

            currentExpandedContent
                .padding(.horizontal, appState.contentHorizontalPadding)
                .padding(.top, appState.contentTopPadding)
                .padding(.bottom, appState.contentBottomPadding)
                .frame(
                    width: contentWidth,
                    height: contentHeight,
                    alignment: .top
                )
                .clipped()

            Spacer(minLength: 0)
        }
        .frame(width: surfaceSize.width, height: surfaceSize.height, alignment: .top)
    }

    @ViewBuilder
    private var currentExpandedContent: some View {
        switch appState.currentState {
        case .compact:
            EmptyView()
        case .expanded:
            ExpandedView()
                .scaleEffect(appState.expandedContentScale, anchor: .top)
                .padding(.top, appState.expandedContentTopOffset)
        case .fullExpanded:
            FullExpandedView()
        }
    }

    // MARK: - Gestures

    private func handleSwipe(value: DragGesture.Value) {
        let horizontal = value.translation.width
        let vertical = value.translation.height
        let velocity = sqrt(pow(value.velocity.width, 2) + pow(value.velocity.height, 2))

        guard velocity > 35 || abs(horizontal) > 14 || abs(vertical) > 18 else { return }

        if abs(horizontal) > abs(vertical) {
            if appState.currentState != .compact {
                handleHorizontalSwipe(horizontal > 0 ? .right : .left)
            }
        } else {
            if vertical < 0 {
                if appState.currentState != .fullExpanded {
                    appState.open()
                }
            } else {
                appState.dismiss()
            }
        }
    }

    private func handleHorizontalSwipe(_ direction: SwipeDirection) {
        if appState.currentState == .expanded && appState.activeBuiltInModule == .nowPlaying {
            NowPlayingManager.shared.skipTrack(forward: direction == .left)
        } else {
            appState.cycleModule(forward: direction == .left)
        }
    }

    private func handleSurfaceTap() {
        if handleNotificationTapIfNeeded() {
            return
        }

        switch appState.currentState {
        case .compact, .expanded:
            appState.open()
        case .fullExpanded:
            break
        }
    }

    private func handleNotificationTapIfNeeded() -> Bool {
        guard appState.activeBuiltInModule == .notifications,
              let notification = NotificationManager.shared.latestNotification else {
            return false
        }

        if notification.tapAction != nil {
            NotificationManager.shared.activateNotification(notification)
            return true
        }

        if appState.currentState != .fullExpanded {
            appState.setActiveModule(.notifications)
            appState.fullyExpand()
            return true
        }

        return false
    }

    // MARK: - Shelf Drop

    private func handleShelfDropTargetChange(_ isTargeted: Bool) {
        guard appState.shelfEnabled else { return }

        if isTargeted {
            shelfDragEndWorkItem?.cancel()
            shelfDragEndWorkItem = nil
            appState.beginShelfDragPresentation()
            return
        }

        let workItem = DispatchWorkItem {
            guard !isShelfDropTargeted else { return }
            appState.endShelfDragPresentation()
            shelfDragEndWorkItem = nil
        }
        shelfDragEndWorkItem?.cancel()
        shelfDragEndWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    // MARK: - Module Cycler

    private var showModuleCycler: Bool {
        appState.currentState != .compact && enabledModuleCount > 1
    }

    private var enabledModuleCount: Int {
        appState.availableModules.count
    }

    private var moduleCyclerOverlay: some View {
        let windowWidth = appState.windowSize.width
        return HStack {
            moduleCycleButton(systemName: "chevron.left", forward: false)
            Spacer()
            moduleCycleButton(systemName: "chevron.right", forward: true)
        }
        .padding(.horizontal, (Constants.moduleCyclerGutterWidth - Constants.moduleCyclerButtonSize) / 2)
        .padding(.top, appState.currentContentTopInset)
        .frame(width: windowWidth, height: appState.currentContentFrameHeight, alignment: .center)
        .frame(maxHeight: .infinity, alignment: .top)
        .opacity(appState.isHovering ? 1 : 0.78)
        .animation(.easeOut(duration: 0.18), value: appState.isHovering)
        .transition(.opacity)
        .allowsHitTesting(appState.currentState != .compact)
    }

    private func moduleCycleButton(systemName: String, forward: Bool) -> some View {
        Button {
            appState.cycleModule(forward: forward)
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.white.opacity(0.95))
                .frame(width: Constants.moduleCyclerButtonSize, height: Constants.moduleCyclerButtonSize)
                .background(
                    Circle()
                        .fill(.black.opacity(appState.isHovering ? 0.9 : 0.8))
                )
                .overlay(
                    Circle()
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .hoverPointer()
        .onHover { hovering in
            setCycleButtonHover(hovering, forward: forward)
        }
        .help(forward ? "Next module" : "Previous module")
    }

    // MARK: - Hover

    private func setIslandSurfaceHover(_ hovering: Bool) {
        guard isHoveringIslandSurface != hovering else { return }
        isHoveringIslandSurface = hovering
        syncHoverState()
    }

    private func handleSurfaceHover(phase: HoverPhase, surfaceSize: CGSize) {
        switch phase {
        case .active(let location):
            guard appState.currentState == .compact,
                  appState.shouldUseMinimalCompactLayout else {
                setIslandSurfaceHover(true)
                return
            }

            let centerGapWidth = appState.compactMinimalCenterGapWidth
            let centerMinX = max(0, (surfaceSize.width - centerGapWidth) / 2)
            let centerMaxX = min(surfaceSize.width, centerMinX + centerGapWidth)
            let hoveringCenter = location.x >= centerMinX && location.x <= centerMaxX
            setIslandSurfaceHover(hoveringCenter)
        case .ended:
            setIslandSurfaceHover(false)
        }
    }

    private func setCycleButtonHover(_ hovering: Bool, forward: Bool) {
        if forward {
            guard isHoveringNextButton != hovering else { return }
            isHoveringNextButton = hovering
        } else {
            guard isHoveringPreviousButton != hovering else { return }
            isHoveringPreviousButton = hovering
        }
        syncHoverState()
    }

    private func syncHoverState() {
        appState.handleHoverChange(
            isHoveringIslandSurface || isHoveringPreviousButton || isHoveringNextButton
        )
    }

    private func validateHoverState() {
        guard appState.isHovering else { return }
        let islandPanels = NSApp.windows.compactMap { $0 as? IslandPanel }
        guard !islandPanels.isEmpty else { return }

        let pointerLocation = NSEvent.mouseLocation
        // Multi-display: hover is valid if the pointer is over ANY island.
        guard !islandPanels.contains(where: { $0.frame.contains(pointerLocation) }) else { return }

        isHoveringIslandSurface = false
        isHoveringPreviousButton = false
        isHoveringNextButton = false
        syncHoverState()
    }
}

private struct IslandSurfaceSwipeModifier: ViewModifier {
    let enabled: Bool
    let isCompact: Bool
    let onTrackpad: (SwipeDirection) -> Void
    let onDragEnded: (DragGesture.Value) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .onTrackpadSwipe { direction in
                    guard !isCompact else { return }
                    onTrackpad(direction)
                }
                .gesture(
                    DragGesture(minimumDistance: 8)
                        .onEnded { value in
                            onDragEnded(value)
                        }
                )
        } else {
            content
        }
    }
}
