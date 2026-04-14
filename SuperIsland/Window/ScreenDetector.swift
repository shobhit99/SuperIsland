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

    /// Stable, per-display identifier string (`CGDirectDisplayID` as text).
    /// Persisted in settings so the user's chosen display survives relaunches.
    static func displayIDString(for screen: NSScreen) -> String? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else {
            return nil
        }
        return String(number.uint32Value)
    }

    /// Find a screen by the identifier produced by `displayIDString`.
    static func screen(withIDString id: String) -> NSScreen? {
        guard !id.isEmpty else { return nil }
        return NSScreen.screens.first { displayIDString(for: $0) == id }
    }

    /// Human-readable list of the connected screens for the display picker.
    /// First entry is always "Automatic" (empty id == follow default rules).
    struct ScreenOption: Identifiable, Hashable {
        let id: String           // "" for Automatic, otherwise CGDirectDisplayID string
        let name: String
    }

    static func availableScreenOptions() -> [ScreenOption] {
        var options: [ScreenOption] = [ScreenOption(id: "", name: "Automatic")]
        for screen in NSScreen.screens {
            guard let id = displayIDString(for: screen) else { continue }
            let name: String
            if #available(macOS 14.0, *), !screen.localizedName.isEmpty {
                name = screen.localizedName
            } else {
                let size = screen.frame.size
                name = "Display (\(Int(size.width))×\(Int(size.height)))"
            }
            let suffix = hasNotch(screen: screen) ? " — notch" : ""
            options.append(ScreenOption(id: id, name: name + suffix))
        }
        return options
    }
}
