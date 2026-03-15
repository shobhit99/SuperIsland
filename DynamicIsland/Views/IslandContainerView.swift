import SwiftUI

struct IslandContainerView: View {
    private struct SurfaceTransition {
        let fromState: IslandState
        let toState: IslandState
    }

    @EnvironmentObject var appState: AppState
    @State private var isHoveringIslandSurface = false
    @State private var isHoveringPreviousButton = false
    @State private var isHoveringNextButton = false
    @State private var isShelfDropTargeted = false
    @State private var shelfDragEndWorkItem: DispatchWorkItem?
    @State private var surfaceScale: CGFloat = 1.0
    @State private var surfaceTransition: SurfaceTransition?
    @State private var surfaceTransitionResetWorkItem: DispatchWorkItem?

    var body: some View {
        islandBody
    }

    private var islandBody: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                islandSurface(in: geometry.size)

                if showModuleCycler {
                    moduleCyclerOverlay
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .opacity(compactContentOpacity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .animation(.spring(response: 0.48, dampingFraction: 0.8), value: appState.activeModule)
        .onChange(of: appState.currentState) { oldValue, newValue in
            handleStateAnimation(from: oldValue, to: newValue)
        }
        .onChange(of: isShelfDropTargeted) { _, isTargeted in
            handleShelfDropTargetChange(isTargeted)
        }
        .onChange(of: showModuleCycler) { _, isVisible in
            guard !isVisible else { return }
            setCycleButtonHover(false, forward: false)
            setCycleButtonHover(false, forward: true)
        }
        .gesture(
            DragGesture(minimumDistance: 8)
                .onEnded { value in
                    handleSwipe(value: value)
                }
        )
        .gesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in
                    AppDelegate.showSettingsWindow()
                }
        )
    }

    @ViewBuilder
    private func islandSurface(in availableSize: CGSize) -> some View {
        let surfaceSize = displayedSurfaceSize(in: availableSize)
        let surface = ZStack(alignment: .top) {
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

            islandContent(in: surfaceSize)
                .frame(width: surfaceSize.width, height: surfaceSize.height, alignment: .top)
                .clipShape(islandShape)
        }
        .frame(width: surfaceSize.width, height: surfaceSize.height)
        .clipped()
        .clipShape(islandShape)
        .scaleEffect(surfaceScale, anchor: .top)
        .overlay {
            if appState.shelfEnabled && isShelfDropTargeted {
                islandShape
                    .stroke(Color.accentColor.opacity(0.92), style: StrokeStyle(lineWidth: 3, dash: [10]))
                    .padding(1)
            }
        }
        .contentShape(islandShape)
        .onHover(perform: setIslandSurfaceHover)
        .onDrop(of: ShelfStore.acceptedDropTypes, isTargeted: $isShelfDropTargeted) { providers in
            guard appState.shelfEnabled else { return false }
            return ShelfStore.shared.handleDrop(providers: providers) { addedCount in
                guard addedCount > 0 else { return }
                shelfDragEndWorkItem?.cancel()
                shelfDragEndWorkItem = nil
                appState.presentShelfAfterDrop()
            }
        }

        if appState.currentState == .fullExpanded {
            surface
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            surface.onTapGesture(perform: handleSurfaceTap)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder
    private func islandContent(in surfaceSize: CGSize) -> some View {
        if appState.currentState == .compact {
            CompactView()
                .opacity(compactContentOpacity)
                .transition(.opacity)
        } else {
            expandedIslandLayout(in: surfaceSize)
                .opacity(compactContentOpacity)
        }
    }

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

    private var compactContentOpacity: Double {
        appState.currentState == .compact ? appState.idleOpacity : 1.0
    }

    private var ambientShadowOpacity: Double {
        appState.currentState == .compact ? 0.24 : 0.34
    }

    private var ambientShadowRadius: CGFloat {
        appState.currentState == .compact ? 4 : 6
    }

    private var ambientShadowYOffset: CGFloat {
        appState.currentState == .compact ? 3 : 5
    }

    private var keyShadowOpacity: Double {
        appState.currentState == .compact ? 0.42 : 0.52
    }

    private var keyShadowRadius: CGFloat {
        appState.currentState == .compact ? 8 : 11
    }

    private var keyShadowYOffset: CGFloat {
        appState.currentState == .compact ? 6 : 8
    }

    private func expandedIslandLayout(in surfaceSize: CGSize) -> some View {
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

    private func handleSwipe(value: DragGesture.Value) {
        let horizontal = value.translation.width
        let vertical = value.translation.height
        let velocity = sqrt(pow(value.velocity.width, 2) + pow(value.velocity.height, 2))

        guard velocity > 35 || abs(horizontal) > 14 || abs(vertical) > 18 else { return }

        if abs(horizontal) > abs(vertical) {
            // Horizontal navigation stays on the module arrows.
            return
        } else {
            // Vertical swipe
            if vertical < 0 {
                // Swipe up -> open
                if appState.currentState != .fullExpanded {
                    appState.open()
                }
            } else {
                // Swipe down -> collapse
                appState.dismiss()
            }
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

    private var showModuleCycler: Bool {
        appState.currentState != .compact && enabledModuleCount > 1
    }

    private var enabledModuleCount: Int {
        appState.availableModules.count
    }

    private var moduleCyclerOverlay: some View {
        HStack {
            moduleCycleButton(systemName: "chevron.left", forward: false)
            Spacer()
            moduleCycleButton(systemName: "chevron.right", forward: true)
        }
        .padding(.horizontal, (Constants.moduleCyclerGutterWidth - Constants.moduleCyclerButtonSize) / 2)
        .padding(.top, appState.currentContentTopInset)
        .frame(height: appState.currentContentFrameHeight, alignment: .center)
        .frame(maxHeight: .infinity, alignment: .top)
        .opacity(appState.isHovering ? 1 : 0.78)
        .animation(.easeOut(duration: 0.18), value: appState.isHovering)
        .transition(.opacity)
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

    private func setIslandSurfaceHover(_ hovering: Bool) {
        guard isHoveringIslandSurface != hovering else { return }
        isHoveringIslandSurface = hovering
        syncHoverState()
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

    private func handleStateAnimation(from oldValue: IslandState, to newValue: IslandState) {
        guard oldValue != newValue else { return }
        surfaceTransition = SurfaceTransition(fromState: oldValue, toState: newValue)
        surfaceTransitionResetWorkItem?.cancel()

        let resetWorkItem = DispatchWorkItem { surfaceTransition = nil }
        surfaceTransitionResetWorkItem = resetWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: resetWorkItem)

        // Overshoot + settle is driven by the AppKit window frame animation
        // in IslandWindowController — no SwiftUI scaleEffect needed.
    }

    private func displayedSurfaceSize(in availableSize: CGSize) -> CGSize {
        guard let surfaceTransition else {
            return appState.currentSize
        }
        let fromSurfaceSize = appState.size(for: surfaceTransition.fromState)
        let toSurfaceSize = appState.size(for: surfaceTransition.toState)
        let progress = currentTransitionProgress(in: availableSize)

        return CGSize(
            width: interpolatedValue(
                from: fromSurfaceSize.width,
                to: toSurfaceSize.width,
                progress: progress
            ),
            height: interpolatedValue(
                from: fromSurfaceSize.height,
                to: toSurfaceSize.height,
                progress: progress
            )
        )
    }

    private func currentTransitionProgress(in availableSize: CGSize) -> CGFloat {
        guard let surfaceTransition else {
            return 1
        }

        return transitionProgress(
            currentSize: availableSize,
            fromSize: appState.windowSize(for: surfaceTransition.fromState),
            toSize: appState.windowSize(for: surfaceTransition.toState)
        )
    }

    private func transitionProgress(
        currentSize: CGSize,
        fromSize: CGSize,
        toSize: CGSize
    ) -> CGFloat {
        let widthProgress = normalizedProgress(
            current: currentSize.width,
            from: fromSize.width,
            to: toSize.width
        )
        let heightProgress = normalizedProgress(
            current: currentSize.height,
            from: fromSize.height,
            to: toSize.height
        )

        let hasWidthChange = abs(toSize.width - fromSize.width) > 0.5
        let hasHeightChange = abs(toSize.height - fromSize.height) > 0.5

        if hasWidthChange && hasHeightChange {
            return max(widthProgress, heightProgress)
        }
        if hasWidthChange {
            return widthProgress
        }
        return heightProgress
    }

    private func normalizedProgress(current: CGFloat, from: CGFloat, to: CGFloat) -> CGFloat {
        let delta = to - from
        guard abs(delta) > 0.5 else { return 1 }
        let progress = (current - from) / delta
        return max(progress, 0) // Allow > 1.0 so the surface follows window overshoot
    }

    private func interpolatedValue(from: CGFloat, to: CGFloat, progress: CGFloat) -> CGFloat {
        from + ((to - from) * progress)
    }
}
