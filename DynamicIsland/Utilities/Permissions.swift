import AppKit
import AVFoundation
import CoreBluetooth
import CoreGraphics
import CoreLocation
import EventKit
import UserNotifications

enum PermissionType: CaseIterable {
    case accessibility
    case screenRecording
    case calendar
    case notifications
    case microphone
    case location
    case bluetooth

    var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        case .calendar: return "Calendar"
        case .notifications: return "Notifications"
        case .microphone: return "Microphone"
        case .location: return "Location"
        case .bluetooth: return "Bluetooth"
        }
    }

    var description: String {
        switch self {
        case .accessibility: return "Needed for gesture detection and system event monitoring"
        case .screenRecording: return "Lets DynamicIsland appear properly in screen recordings"
        case .calendar: return "Show upcoming events in the Dynamic Island"
        case .notifications: return "Mirror notifications in the Dynamic Island"
        case .microphone: return "Audio visualization for the spectrogram"
        case .location: return "Provide weather information for your location"
        case .bluetooth: return "Show connected device notifications"
        }
    }

    var iconName: String {
        switch self {
        case .accessibility: return "figure.stand"
        case .screenRecording: return "display"
        case .calendar: return "calendar"
        case .notifications: return "bell.badge.fill"
        case .microphone: return "mic.fill"
        case .location: return "location.fill"
        case .bluetooth: return "wave.3.right.circle.fill"
        }
    }

    var isRequired: Bool {
        switch self {
        case .accessibility, .screenRecording:
            return true
        case .calendar, .notifications, .microphone, .location, .bluetooth:
            return false
        }
    }
}

private final class LocationDelegate: NSObject, CLLocationManagerDelegate {
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorizationChange?(manager.authorizationStatus)
    }
}

final class PermissionsManager {
    static let shared = PermissionsManager()
    private static let accessibilityPromptedDefaultsKey = "permissions.accessibilityPrompted"
    private var locationManager: CLLocationManager?
    private let locationDelegate = LocationDelegate()
    private var calendarStore: EKEventStore?
    private var bluetoothTrigger: CBCentralManager?

    private init() {}

    // MARK: - Unified API

    func check(_ permission: PermissionType) -> Bool {
        switch permission {
        case .accessibility:
            return checkAccessibility()
        case .screenRecording:
            return checkScreenRecording()
        case .calendar:
            return checkCalendar()
        case .notifications:
            // Notifications require async check — return false for sync callers.
            // Use notificationsGranted() for the accurate async result.
            return false
        case .microphone:
            return checkMicrophone()
        case .location:
            return checkLocation()
        case .bluetooth:
            return checkBluetooth()
        }
    }

    func request(_ permission: PermissionType) {
        switch permission {
        case .accessibility:
            requestAccessibility()
        case .screenRecording:
            _ = requestScreenRecordingAccess()
        case .calendar:
            Task { @MainActor in _ = await requestCalendarAccess() }
        case .notifications:
            Task { _ = await requestNotificationAccess() }
        case .microphone:
            requestMicrophoneAccess()
        case .location:
            requestLocationAccess()
        case .bluetooth:
            openBluetoothSettings()
        }
    }

    // MARK: - Accessibility

    func checkAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
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

    func checkCalendar() -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess, .authorized:
            return true
        default:
            return false
        }
    }

    @MainActor func requestCalendarAccess() async -> Bool {
        if calendarStore == nil { calendarStore = EKEventStore() }

        await MainActor.run { NSApp.activate(ignoringOtherApps: true) }

        // Call unconditionally — the API handles all states internally:
        // .notDetermined  → shows TCC dialog
        // .fullAccess     → returns true immediately (already granted)
        // .denied         → throws (caught by try?, falls through to Settings)
        // On macOS 15 the default pre-request status may not be .notDetermined,
        // so checking status first would skip the dialog entirely.
        if let granted = try? await calendarStore!.requestFullAccessToEvents(), granted {
            return true
        }

        // Open System Settings so the user can grant Full Access manually.
        await MainActor.run { openCalendarSettings() }
        return false
    }

    // MARK: - Notifications

    func notificationsGranted() async -> Bool {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus == .authorized)
            }
        }
    }

    func requestNotificationAccess() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    // MARK: - Microphone

    func checkMicrophone() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func requestMicrophoneAccess() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    // MARK: - Location

    func checkLocation() -> Bool {
        ensureLocationManager()
        return isAuthorizedLocationStatus(locationManager!.authorizationStatus)
    }

    func requestLocationAccess() {
        ensureLocationManager()
        let status = locationManager!.authorizationStatus
        guard !isAuthorizedLocationStatus(status) else { return }

        if status == .denied || status == .restricted {
            openLocationSettings()
            return
        }

        // .notDetermined — request authorization, then open Settings as fallback
        NSApp.activate(ignoringOtherApps: true)
        locationManager?.requestWhenInUseAuthorization()

        // If the system dialog doesn't appear (LSUIElement quirk), open Settings
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, let mgr = self.locationManager else { return }
            if mgr.authorizationStatus == .notDetermined {
                self.openLocationSettings()
            }
        }
    }

    private func ensureLocationManager() {
        guard locationManager == nil else { return }
        locationManager = CLLocationManager()
        locationManager?.delegate = locationDelegate
        locationDelegate.onAuthorizationChange = { [weak self] status in
            guard let self else { return }
            if self.isAuthorizedLocationStatus(status) {
                self.locationManager?.requestLocation()
            }
        }
    }

    private func isAuthorizedLocationStatus(_ status: CLAuthorizationStatus) -> Bool {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse, .authorized:
            return true
        default:
            return false
        }
    }

    // MARK: - Bluetooth

    func checkBluetooth() -> Bool {
        let auth = CBManager.authorization
        return auth == .allowedAlways
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

    func openCalendarSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
        NSWorkspace.shared.open(url)
    }

    func openNotificationsSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
        NSWorkspace.shared.open(url)
    }

    func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }

    func openLocationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!
        NSWorkspace.shared.open(url)
    }

    func openBluetoothSettings() {
        // Creating a CBCentralManager triggers the system Bluetooth permission prompt,
        // which registers DynamicIsland in the Bluetooth privacy list.
        if bluetoothTrigger == nil {
            bluetoothTrigger = CBCentralManager()
        }
        // Give the system a moment to register the app, then open Settings
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!
            NSWorkspace.shared.open(url)
        }
    }
}
