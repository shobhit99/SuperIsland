import AppKit

enum ScreenDetector {
    struct CompactIslandMetrics {
        let size: CGSize
        let bottomCornerRadius: CGFloat
    }

    /// Check if the given screen has a notch (MacBook Pro 14"/16" etc.)
    static func hasNotch(screen: NSScreen) -> Bool {
        if #available(macOS 12.0, *) {
            guard let _ = screen.auxiliaryTopLeftArea,
                  let _ = screen.auxiliaryTopRightArea else {
                return false
            }
            return true
        }
        return false
    }

    /// Get the notch rectangle area for positioning
    static func notchRect(screen: NSScreen) -> NSRect? {
        if #available(macOS 12.0, *) {
            guard let topLeft = screen.auxiliaryTopLeftArea,
                  let topRight = screen.auxiliaryTopRightArea else {
                return nil
            }

            let screenFrame = screen.frame
            // The notch is between the two auxiliary areas
            let notchX = screenFrame.origin.x + topLeft.width
            let notchWidth = screenFrame.width - topLeft.width - topRight.width
            let notchY = screenFrame.maxY - max(topLeft.height, topRight.height)
            let notchHeight = max(topLeft.height, topRight.height)

            return NSRect(x: notchX, y: notchY, width: notchWidth, height: notchHeight)
        }
        return nil
    }

    static func compactIslandMetrics(screen: NSScreen) -> CompactIslandMetrics? {
        guard let notch = notchRect(screen: screen) else {
            return nil
        }

        let width = max(
            Constants.compactNotchMinimumWidth,
            notch.width - (Constants.compactNotchHorizontalInset * 2)
        )
        let height = max(
            Constants.compactNotchMinimumHeight,
            notch.height - Constants.compactNotchHeightInset
        )
        let bottomCornerRadius = min(Constants.compactNotchBottomCornerRadius, height / 2)

        return CompactIslandMetrics(
            size: CGSize(width: width, height: height),
            bottomCornerRadius: bottomCornerRadius
        )
    }

    /// Get the screen that the mouse cursor is currently on
    static var activeScreen: NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { screen in
            screen.frame.contains(mouseLocation)
        }
    }

    /// Get the primary screen
    static var primaryScreen: NSScreen? {
        NSScreen.main
    }
}
