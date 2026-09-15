import AppKit
import AVFoundation
import CoreBluetooth
import CoreGraphics
import CoreLocation
import EventKit
import Speech
import UserNotifications

enum PermissionType: CaseIterable {
    case accessibility
    case screenRecording
    case calendar
    case notifications
    case microphone
    case speechRecognition
    case location
    case bluetooth

    var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        case .calendar: return "Calendar"
        case .notifications: return "Notifications"
        case .microphone: return "Microphone"
        case .speechRecognition: return "Speech Recognition"
        case .location: return "Location"
        case .bluetooth: return "Bluetooth"
        }
    }

    var description: String {
        switch self {
        case .accessibility: return "Needed for gesture detection and system event monitoring"
        case .screenRecording: return "Lets SuperIsland appear properly in screen recordings"
        case .calendar: return "Show upcoming events in the Super Island"
        case .notifications: return "Show supported notification sources in the Super Island"
        case .microphone: return "Audio visualization for the spectrogram"
        case .speechRecognition: return "Follow along with Teleprompter scripts as you read"
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
        case .speechRecognition: return "text.word.spacing"
        case .location: return "location.fill"
        case .bluetooth: return "wave.3.right.circle.fill"
        }
    }

    var isRequired: Bool {
        switch self {
        case .accessibility, .screenRecording:
            return true
        case .calendar, .notifications, .microphone, .speechRecognition, .location, .bluetooth:
            return false
        }
    }
}

final class PermissionsLocationDelegate: NSObject, CLLocationManagerDelegate {
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorizationChange?(manager.authorizationStatus)
    }

    // PermissionsManager never consumes location fixes — WeatherManager owns its
    // own CLLocationManager for that. These are still implemented because
    // CLLocationManager.requestLocation() raises
    // "Delegate must respond to locationManager:didUpdateLocations:" if any code
    // path ever routes a location request through this manager.
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

final class PermissionsManager {
    static let shared = PermissionsManager()
    private static let accessibilityPromptedDefaultsKey = "permissions.accessibilityPrompted"
    private var locationManager: CLLocationManager?
    private let locationDelegate = PermissionsLocationDelegate()
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
        case .speechRecognition:
            return checkSpeechRecognition()
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
        case .speechRecognition:
            requestSpeechRecognitionAccess()
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
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    continuation.resume(returning: true)
                case .notDetermined, .denied:
                    continuation.resume(returning: false)
                @unknown default:
                    continuation.resume(returning: false)
                }
            }
        }
    }

    func requestNotificationAccess() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    // MARK: - Microphone

    func checkMicrophone() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func microphoneAuthorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func requestMicrophoneAccess(completion: ((Bool) -> Void)? = nil) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .authorized {
            completion?(true)
            return
        }
        if status == .denied || status == .restricted {
            openMicrophoneSettings()
            completion?(false)
            return
        }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    completion?(granted)
                }
            }
        }
    }

    // MARK: - Speech Recognition

    func checkSpeechRecognition() -> Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    func speechRecognitionAuthorizationStatus() -> SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    func requestSpeechRecognitionAccess(completion: ((Bool) -> Void)? = nil) {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized {
            completion?(true)
            return
        }
        if status == .denied || status == .restricted {
            openSpeechRecognitionSettings()
            completion?(false)
            return
        }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async {
                    completion?(status == .authorized)
                }
            }
        }
    }

    func requestTeleprompterWordTrackingAccess(completion: ((Bool) -> Void)? = nil) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)

            let requestGroup = DispatchGroup()
            var microphoneGranted = self.checkMicrophone()
            var speechGranted = self.checkSpeechRecognition()

            requestGroup.enter()
            self.requestMicrophoneAccess { granted in
                microphoneGranted = granted
                requestGroup.leave()
            }

            requestGroup.enter()
            self.requestSpeechRecognitionAccess { granted in
                speechGranted = granted
                requestGroup.leave()
            }

            requestGroup.notify(queue: .main) {
                completion?(microphoneGranted && speechGranted)
            }
        }
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
        locationManager?.requestAlwaysAuthorization()

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
        // Deliberately no location request here: PermissionsManager only checks
        // and requests authorization. Fetching an actual fix is WeatherManager's
        // job — its own CLLocationManager receives the same authorization
        // callback and starts updating once access is granted. Requesting a
        // location from this manager used to trip a CoreLocation assertion
        // ("Delegate must respond to locationManager:didUpdateLocations:") that
        // broke location delivery for the whole process.
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

    func openSpeechRecognitionSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")!
        NSWorkspace.shared.open(url)
    }

    func openLocationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!
        NSWorkspace.shared.open(url)
    }

    func openBluetoothSettings() {
        // Creating a CBCentralManager triggers the system Bluetooth permission prompt,
        // which registers SuperIsland in the Bluetooth privacy list.
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
