import SwiftUI

struct IslandContainerView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        islandBody
    }

    private var islandBody: some View {
        GeometryReader { geometry in
            ZStack {
                // The pill background
                PillShape(cornerRadius: appState.currentCornerRadius)
                    .fill(.black)
                    .shadow(color: .black.opacity(0.3), radius: appState.currentState == .compact ? 0 : 10, y: 5)

                // Content overlay follows the panel size directly to avoid double-resizing.
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
                .frame(
                    width: max(0, geometry.size.width - 16),
                    height: max(0, geometry.size.height - 8)
                )
                .clipped()
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: appState.activeModule)
        .opacity(appState.currentState == .compact ? appState.idleOpacity : 1.0)
        .contentShape(PillShape(cornerRadius: appState.currentCornerRadius))
        .onTapGesture {
            switch appState.currentState {
            case .compact:
                appState.expand()
            case .expanded:
                appState.fullyExpand()
            case .fullExpanded:
                appState.dismiss()
            }
        }
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
            DragGesture(minimumDistance: 20)
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

    private func handleSwipe(value: DragGesture.Value) {
        let horizontal = value.translation.width
        let vertical = value.translation.height
        let velocity = sqrt(pow(value.velocity.width, 2) + pow(value.velocity.height, 2))

        guard velocity > 100 else { return }

        if abs(horizontal) > abs(vertical) {
            // Horizontal swipe
            if horizontal > 0 {
                appState.cycleModule(forward: true)
            } else {
                appState.cycleModule(forward: false)
            }
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
}
