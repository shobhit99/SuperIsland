import SwiftUI

struct IslandContainerView: View {
    @EnvironmentObject var appState: AppState
    @State private var isHoveringIslandSurface = false
    @State private var isHoveringPreviousButton = false
    @State private var isHoveringNextButton = false

    var body: some View {
        islandBody
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
        .contentShape(islandShape)
        .onHover(perform: setIslandSurfaceHover)

        if appState.currentState == .fullExpanded {
            surface
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            surface.onTapGesture {
                switch appState.currentState {
                case .compact, .expanded:
                    appState.open()
                case .fullExpanded:
                    break
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
}
