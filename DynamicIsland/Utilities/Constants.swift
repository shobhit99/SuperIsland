import SwiftUI

enum Constants {
    // MARK: - Island Sizes
    static let compactSize = CGSize(width: 200, height: 36)
    static let expandedSize = CGSize(width: 408, height: 88)
    static let fullExpandedSize = CGSize(width: 658, height: 180)

    // MARK: - Window
    static let windowMaxWidth: CGFloat = 420
    static let windowMaxHeight: CGFloat = 260
    static let moduleCyclerGutterWidth: CGFloat = 52
    static let moduleCyclerButtonSize: CGFloat = 24
    static let expandedShadowBottomPadding: CGFloat = 40
    static let expandedNotchHeightBoost: CGFloat = 5
    static let compactNotchHorizontalInset: CGFloat = 1
    static let compactNotchHeightInset: CGFloat = -4
    static let compactNotchBottomCornerRadius: CGFloat = 12
    static let compactNotchMinimumWidth: CGFloat = 168
    static let compactNotchMinimumHeight: CGFloat = 32
    static let compactNotchVerticalOffset: CGFloat = 0
    static let compactMinimalSideExpansion: CGFloat = 56
    static let compactMinimalHorizontalPadding: CGFloat = 14
    static let compactMinimalSafeSideMargin: CGFloat = 24
    static let expandedTopInset: CGFloat = 0
    static let compactCornerRadius: CGFloat = 18
    static let expandedCornerRadius: CGFloat = 22
    static let fullExpandedCornerRadius: CGFloat = 40

    // MARK: - Animation Springs
    /// Single unified spring for all expand/shrink transitions (à la NotchDrop).
    static let notchAnimation: Animation = .interactiveSpring(
        duration: 0.5,
        extraBounce: 0.25,
        blendDuration: 0.125
    )
    static let hudAppear: Animation = notchAnimation
    static let hudDismiss: Animation = notchAnimation
    static let progressBar: Animation = .easeInOut(duration: 0.15)
    static let contentSwap: Animation = .smooth(duration: 0.22)
    static let overshootBounce: Animation = .spring(response: 0.36, dampingFraction: 0.68)

    // MARK: - Timing
    static let hudAutoDismissDelay: TimeInterval = 1.5
    static let hoverPeekDelay: TimeInterval = 0.3
    static let notificationDisplayDuration: TimeInterval = 2.0
    static let notificationHoverFullExpandWindow: TimeInterval = 10.0
    static let weatherRefreshInterval: TimeInterval = 1800 // 30 minutes

    // MARK: - Menu Bar
    static let menuBarIconName = "rectangle.on.rectangle.angled"
}
