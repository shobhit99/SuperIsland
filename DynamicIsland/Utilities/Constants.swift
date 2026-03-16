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
    static let compactNotchHeightInset: CGFloat = 2
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
    static let compactToExpanded: Animation = .interactiveSpring(response: 0.46, dampingFraction: 0.78, blendDuration: 0.08)
    static let expandedToCompact: Animation = .interactiveSpring(response: 0.5, dampingFraction: 0.96, blendDuration: 0.06)
    static let expandedToFull: Animation = .interactiveSpring(response: 0.5, dampingFraction: 0.88, blendDuration: 0.08)
    static let hudAppear: Animation = compactToExpanded
    static let hudDismiss: Animation = expandedToCompact
    static let progressBar: Animation = .easeInOut(duration: 0.15)
    static let contentSwap: Animation = .smooth(duration: 0.22)
    static let overshootBounce: Animation = .spring(response: 0.36, dampingFraction: 0.68)
    static let expansionOvershoot: Animation = .spring(response: 0.32, dampingFraction: 0.72)
    static let expansionSettle: Animation = .spring(response: 0.38, dampingFraction: 0.86)

    // MARK: - Timing
    static let hudAutoDismissDelay: TimeInterval = 1.5
    static let hoverPeekDelay: TimeInterval = 0.3
    static let notificationDisplayDuration: TimeInterval = 2.0
    static let notificationHoverFullExpandWindow: TimeInterval = 10.0
    static let weatherRefreshInterval: TimeInterval = 1800 // 30 minutes

    // MARK: - Menu Bar
    static let menuBarIconName = "rectangle.on.rectangle.angled"
}
