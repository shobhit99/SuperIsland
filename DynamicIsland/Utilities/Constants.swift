import SwiftUI

enum Constants {
    // MARK: - Island Sizes
    static let compactSize = CGSize(width: 200, height: 36)
    static let expandedSize = CGSize(width: 360, height: 80)
    static let fullExpandedSize = CGSize(width: 400, height: 200)

    // MARK: - Window
    static let windowMaxWidth: CGFloat = 420
    static let windowMaxHeight: CGFloat = 260
    static let compactCornerRadius: CGFloat = 18
    static let expandedCornerRadius: CGFloat = 22
    static let fullExpandedCornerRadius: CGFloat = 26

    // MARK: - Animation Springs
    static let compactToExpanded: Animation = .spring(response: 0.35, dampingFraction: 0.75)
    static let expandedToCompact: Animation = .spring(response: 0.3, dampingFraction: 0.8)
    static let expandedToFull: Animation = .spring(response: 0.4, dampingFraction: 0.7)
    static let hudAppear: Animation = .easeOut(duration: 0.25)
    static let hudDismiss: Animation = .easeIn(duration: 0.2)
    static let progressBar: Animation = .easeInOut(duration: 0.15)
    static let contentSwap: Animation = .easeInOut(duration: 0.2)
    static let overshootBounce: Animation = .spring(response: 0.3, dampingFraction: 0.5)

    // MARK: - Timing
    static let hudAutoDismissDelay: TimeInterval = 1.5
    static let hoverPeekDelay: TimeInterval = 0.3
    static let weatherRefreshInterval: TimeInterval = 1800 // 30 minutes

    // MARK: - Menu Bar
    static let menuBarIconName = "rectangle.on.rectangle.angled"
}
