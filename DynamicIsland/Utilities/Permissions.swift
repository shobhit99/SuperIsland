import AppKit
import EventKit
import CoreLocation
import CoreGraphics
import UserNotifications

enum PermissionType: CaseIterable {
    case accessibility
    case calendar
    case bluetooth
    case location
    case notifications
    case microphone

    var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .calendar: return "Calendar"
        case .bluetooth: return "Bluetooth"
        case .location: return "Location"
        case .notifications: return "Notifications"
        case .microphone: return "Microphone"
        }
    }

    var description: String {
        switch self {
        case .accessibility: return "Needed for gesture detection and system event monitoring"
        case .calendar: return "Show upcoming events in the Dynamic Island"
        case .bluetooth: return "Show connected device notifications"
        case .location: return "Provide weather information for your location"
        case .notifications: return "Mirror notifications in the Dynamic Island"
        case .microphone: return "Audio visualization for the spectrogram"
        }
    }
}

final class PermissionsManager {
    static let shared = PermissionsManager()
    private static let accessibilityPromptedDefaultsKey = "permissions.accessibilityPrompted"

    private init() {}

    // MARK: - Accessibility

    func checkAccessibility() -> Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibility() {
        guard !AXIsProcessTrusted() else { return }
        UserDefaults.standard.set(true, forKey: Self.accessibilityPromptedDefaultsKey)
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Screen Recording

    func checkScreenRecording() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    func requestScreenRecordingAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    // MARK: - Calendar

    func requestCalendarAccess() async -> Bool {
        let store = EKEventStore()
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            return false
        }
    }

    // MARK: - Notifications

    func requestNotificationAccess() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    // MARK: - Open System Settings

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    func openNotificationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
        NSWorkspace.shared.open(url)
    }
}
