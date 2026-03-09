import SwiftUI

struct IslandContainerView: View {
    @EnvironmentObject var appState: AppState
    @State private var surfaceScale: CGFloat = 1.0
    @State private var overshootResetWorkItem: DispatchWorkItem?

    var body: some View {
        islandBody
            .onChange(of: appState.currentState) { oldValue, newValue in
                triggerExpansionOvershoot(from: oldValue, to: newValue)
            }
            .onDisappear {
                overshootResetWorkItem?.cancel()
            }
    }

    private var islandBody: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                islandSurface

                if showModuleCycler {
                    moduleCyclerOverlay
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .opacity(compactContentOpacity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .animation(.spring(response: 0.48, dampingFraction: 0.8), value: appState.activeModule)
        .onHover { hovering in
            appState.handleHoverChange(hovering)
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
    private var islandSurface: some View {
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

            if appState.currentState == .compact {
                CompactView()
                    .opacity(compactContentOpacity)
                    .transition(.opacity)
            } else {
                expandedIslandLayout
                    .opacity(compactContentOpacity)
            }
        }
        .frame(width: appState.currentSize.width, height: appState.currentSize.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(islandShape)
        .scaleEffect(surfaceScale, anchor: surfaceScaleAnchor)

        if appState.currentState == .fullExpanded {
            surface
        } else {
            surface.onTapGesture {
                switch appState.currentState {
                case .compact:
                    appState.expand()
                case .expanded:
                    appState.fullyExpand()
                case .fullExpanded:
                    break
                }
            }
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

    private var surfaceScaleAnchor: UnitPoint {
        appState.currentState == .compact ? .center : .top
    }

    private var shadowBoost: CGFloat {
        max(surfaceScale - 1.0, 0)
    }

    private var ambientShadowOpacity: Double {
        let baseOpacity = appState.currentState == .compact ? 0.24 : 0.34
        return min(baseOpacity + Double(shadowBoost * 1.9), 0.46)
    }

    private var ambientShadowRadius: CGFloat {
        let baseRadius: CGFloat = appState.currentState == .compact ? 4 : 6
        return baseRadius + (shadowBoost * 20)
    }

    private var ambientShadowYOffset: CGFloat {
        let baseOffset: CGFloat = appState.currentState == .compact ? 3 : 5
        return baseOffset + (shadowBoost * 10)
    }

    private var keyShadowOpacity: Double {
        let baseOpacity = appState.currentState == .compact ? 0.42 : 0.52
        return min(baseOpacity + Double(shadowBoost * 2.2), 0.68)
    }

    private var keyShadowRadius: CGFloat {
        let baseRadius: CGFloat = appState.currentState == .compact ? 8 : 11
        return baseRadius + (shadowBoost * 28)
    }

    private var keyShadowYOffset: CGFloat {
        let baseOffset: CGFloat = appState.currentState == .compact ? 6 : 8
        return baseOffset + (shadowBoost * 14)
    }

    private var expandedIslandLayout: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: appState.currentContentTopInset)

            currentExpandedContent
                .padding(.horizontal, appState.contentHorizontalPadding)
                .padding(.top, appState.contentTopPadding)
                .padding(.bottom, appState.contentBottomPadding)
                .frame(
                    width: appState.currentContentSize.width,
                    height: appState.currentContentFrameHeight,
                    alignment: .top
                )
                .clipped()

            Spacer(minLength: 0)
        }
        .frame(width: appState.currentSize.width, height: appState.currentSize.height, alignment: .top)
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
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
        case .fullExpanded:
            FullExpandedView()
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
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
                // Swipe up -> expand
                if appState.currentState == .compact {
                    appState.expand()
                } else if appState.currentState == .expanded {
                    appState.fullyExpand()
                }
            } else {
                // Swipe down -> collapse
                appState.dismiss()
            }
        }
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
        }
        .buttonStyle(.plain)
        .help(forward ? "Next module" : "Previous module")
    }

    private func triggerExpansionOvershoot(from oldState: IslandState, to newState: IslandState) {
        overshootResetWorkItem?.cancel()

        let overshootScale: CGFloat
        switch (oldState, newState) {
        case (.compact, .expanded):
            overshootScale = 1.035
        case (.compact, .fullExpanded):
            overshootScale = 1.04
        case (.expanded, .fullExpanded):
            overshootScale = 1.024
        default:
            overshootScale = 1.0
        }

        guard overshootScale > 1 else {
            withAnimation(.easeOut(duration: 0.12)) {
                surfaceScale = 1.0
            }
            return
        }

        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
            surfaceScale = overshootScale
        }

        let settleWorkItem = DispatchWorkItem {
            withAnimation(.spring(response: 0.44, dampingFraction: 0.88)) {
                surfaceScale = 1.0
            }
        }
        overshootResetWorkItem = settleWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: settleWorkItem)
    }
}
