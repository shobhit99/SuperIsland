import SwiftUI

enum Constants {
    // MARK: - Island Sizes
    static let compactSize = CGSize(width: 188, height: 34)
    static let expandedSize = CGSize(width: 408, height: 88)
    static let fullExpandedSize = CGSize(width: 658, height: 180)

    // MARK: - Window
    static let windowMaxWidth: CGFloat = 420
    static let windowMaxHeight: CGFloat = 260
    static let moduleCyclerGutterWidth: CGFloat = 52
    static let moduleCyclerButtonSize: CGFloat = 24
    static let expandedShadowBottomPadding: CGFloat = 40
    static let expandedNotchHeightBoost: CGFloat = 5
    static let compactNotchHorizontalInset: CGFloat = 4
    static let compactNotchHeightInset: CGFloat = 0
    static let compactNotchBottomCornerRadius: CGFloat = 12
    static let compactNotchMinimumWidth: CGFloat = 160
    static let compactNotchMinimumHeight: CGFloat = 30
    static let compactNotchVerticalOffset: CGFloat = 0
    static let expandedTopInset: CGFloat = 0
    static let compactCornerRadius: CGFloat = 18
    static let expandedCornerRadius: CGFloat = 22
    static let fullExpandedCornerRadius: CGFloat = 32

    // MARK: - Animation Springs
    static let compactToExpanded: Animation = .interactiveSpring(response: 0.38, dampingFraction: 0.8, blendDuration: 0)
    static let expandedToCompact: Animation = .interactiveSpring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)
    static let expandedToFull: Animation = .interactiveSpring(response: 0.42, dampingFraction: 0.82, blendDuration: 0)
    static let hudAppear: Animation = compactToExpanded
    static let hudDismiss: Animation = expandedToCompact
    static let progressBar: Animation = .easeInOut(duration: 0.15)
    static let contentSwap: Animation = .smooth(duration: 0.22)
    static let overshootBounce: Animation = .spring(response: 0.3, dampingFraction: 0.5)

    // MARK: - Timing
    static let hudAutoDismissDelay: TimeInterval = 1.5
    static let hoverPeekDelay: TimeInterval = 0.3
    static let notificationDisplayDuration: TimeInterval = 2.0
    static let weatherRefreshInterval: TimeInterval = 1800 // 30 minutes

    // MARK: - Menu Bar
    static let menuBarIconName = "rectangle.on.rectangle.angled"
}
