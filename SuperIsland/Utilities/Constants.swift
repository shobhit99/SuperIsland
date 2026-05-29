import SwiftUI

enum Constants {

    // MARK: - User-Tweakable
    // These values control timing and behaviour that a regular user may want to
    // adjust.  They are candidates for exposure in the in-app Settings panel
    // (e.g. an "Advanced" or "Behaviour" section).

    /// How long the HUD stays visible before automatically collapsing (seconds).
    static let hudAutoDismissDelay: TimeInterval = 1.5
    /// Delay before the island "peeks" when the cursor hovers near it (seconds).
    static let hoverPeekDelay: TimeInterval = 0.3
    /// How long a notification banner is displayed inside the island (seconds).
    static let notificationDisplayDuration: TimeInterval = 2.0
    /// Window during which hovering over a notification triggers full-expand (seconds).
    static let notificationHoverFullExpandWindow: TimeInterval = 10.0
    /// How often weather data is fetched in the background (seconds). Default = 30 min.
    static let weatherRefreshInterval: TimeInterval = 1800

    // MARK: - Developer / SDK Layout Constants
    // These describe the island's visual geometry and are surfaced to extension
    // authors via `SuperIsland.constants.layout` in the JavaScript SDK.
    // Extension developers should use these values to size and position content
    // so it fits correctly inside each island state.

    /// Compact-pill dimensions on notched MacBooks (SwiftUI points).
    static let compactSize = CGSize(width: 200, height: 36)
    /// Compact-pill dimensions on non-notch Macs (SwiftUI points).
    static let nonNotchCompactSize = CGSize(width: 220, height: 28)
    /// Expanded-drawer dimensions (SwiftUI points).
    static let expandedSize = CGSize(width: 408, height: 88)
    /// Full-expanded panel dimensions (SwiftUI points).
    static let fullExpandedSize = CGSize(width: 658, height: 180)
    /// Corner radius used on the compact island pill.
    static let compactCornerRadius: CGFloat = 18
    /// Corner radius used on the expanded island drawer.
    static let expandedCornerRadius: CGFloat = 22
    /// Corner radius used on the full-expanded panel.
    static let fullExpandedCornerRadius: CGFloat = 40

    // MARK: - Internal Renderer Constants
    // These fine-tune the host-side rendering pipeline and are not exposed to
    // extensions or end-users.  Change them only when adjusting low-level
    // layout or animation behaviour in the native host.

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

    // MARK: - Animation Springs
    // Shared animation curves used by the native host renderer.  Not exposed
    // to extensions — use the `View.animate(child, kind)` DSL in JS instead.

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

    // MARK: - Menu Bar

    static let menuBarIconName = "rectangle.on.rectangle.angled"
}
