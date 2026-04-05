import Foundation
import Combine

final class FocusManager: ObservableObject {
    static let shared = FocusManager()

    @Published var isActive: Bool = false
    @Published var focusName: String = ""

    private init() {
        startMonitoring()
    }

    private func startMonitoring() {
        // Monitor Focus/DND state changes via distributed notifications
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(focusChanged),
            name: NSNotification.Name("com.apple.notificationcenterui.dndState.changed"),
            object: nil
        )

        // Also check initial state
        checkFocusState()
    }

    @objc private func focusChanged(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.checkFocusState()
        }
    }

    private func checkFocusState() {
        // Read DND state from user defaults (com.apple.controlcenter)
        // This is a common technique but may require accessibility permissions
        let dndDefaults = UserDefaults(suiteName: "com.apple.controlcenter")
        let dndEnabled = dndDefaults?.bool(forKey: "NSStatusItem Visible DoNotDisturb") ?? false

        isActive = dndEnabled

        if dndEnabled {
            focusName = "Do Not Disturb"
        } else {
            focusName = ""
        }
    }

    // MARK: - Helpers

    var iconName: String {
        isActive ? "moon.fill" : "moon"
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }
}
