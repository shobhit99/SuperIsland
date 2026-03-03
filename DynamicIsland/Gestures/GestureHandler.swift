import SwiftUI
import Combine

final class GestureHandler: ObservableObject {
    static let shared = GestureHandler()

    @Published var swipeSensitivity: Double = 1.0

    private let appState = AppState.shared

    private init() {}

    // MARK: - Swipe Handling

    func handleSwipe(direction: SwipeDirection, in state: IslandState) {
        switch (direction, state) {
        case (.left, .compact), (.right, .compact):
            // Cycle modules
            appState.cycleModule(forward: direction == .right)
        case (.left, .expanded), (.right, .expanded):
            // If now playing, skip track
            if appState.activeModule == .nowPlaying {
                NowPlayingManager.shared.skipTrack(forward: direction == .right)
            } else {
                appState.cycleModule(forward: direction == .right)
            }
        case (.up, .compact):
            appState.expand()
        case (.up, .expanded):
            appState.fullyExpand()
        case (.down, _):
            appState.dismiss()
        default:
            break
        }
    }

    // MARK: - Tap Handling

    func handleTap(in state: IslandState) {
        appState.toggleExpansion()
    }

    // MARK: - Hover Handling

    func handleHover(_ isHovering: Bool) {
        appState.isHovering = isHovering
    }

    // MARK: - Long Press

    func handleLongPress() {
        AppDelegate.showSettingsWindow()
    }
}

enum SwipeDirection {
    case left, right, up, down
}
