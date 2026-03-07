import SwiftUI

struct IslandContainerView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        islandBody
    }

    private var islandBody: some View {
        GeometryReader { geometry in
            ZStack {
                islandSurface

                if showModuleCycler {
                    moduleCyclerOverlay
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .opacity(compactContentOpacity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: appState.activeModule)
        .onHover { hovering in
            appState.isHovering = hovering
            if hovering && appState.currentState == .compact {
                appState.expand()
            } else if hovering {
                appState.cancelAutoDismiss()
                appState.cancelFullExpandedCollapse()
            } else if appState.currentState == .expanded {
                appState.scheduleAutoDismiss()
            } else if appState.currentState == .fullExpanded {
                appState.scheduleFullExpandedCollapse()
            }
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
        let surface = ZStack {
            islandShape
                .fill(.black)
                .shadow(color: .black.opacity(0.3), radius: appState.currentState == .compact ? 0 : 10, y: 5)

            Group {
                switch appState.currentState {
                case .compact:
                    CompactView()
                        .transition(.opacity)
                case .expanded:
                    ExpandedView()
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                case .fullExpanded:
                    FullExpandedView()
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            .opacity(compactContentOpacity)
            .frame(
                width: max(0, appState.currentSize.width - 16),
                height: max(0, appState.currentSize.height - 8)
            )
            .clipped()
        }
        .frame(width: appState.currentSize.width, height: appState.currentSize.height)
        .contentShape(islandShape)

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
            topCornerRadius: appState.currentTopCornerRadius,
            bottomCornerRadius: appState.currentBottomCornerRadius
        )
    }

    private var compactContentOpacity: Double {
        appState.currentState == .compact ? appState.idleOpacity : 1.0
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
        .padding(.horizontal, 4)
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
}
