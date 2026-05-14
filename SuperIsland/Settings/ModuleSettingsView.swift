import AppKit
import SwiftUI
import UserNotifications

struct ModuleSettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var notificationManager = NotificationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            SettingSectionLabel(title: "Media & HUD")
            SettingGroup {
                SettingToggleRow(title: "Now Playing", isOn: $appState.nowPlayingEnabled)
                SettingRowDivider()
                SettingToggleRow(title: "Volume HUD", isOn: $appState.volumeHUDEnabled)
            }

            SettingSectionLabel(title: "System")
            SettingGroup {
                SettingToggleRow(title: "Battery", isOn: $appState.batteryEnabled)
                SettingRowDivider()
                SettingToggleRow(title: "Shelf", isOn: $appState.shelfEnabled)
                SettingRowDivider()
                SettingToggleRow(title: "Auto-open Shelf on Drop", isOn: $appState.shelfAutoOpenOnDrop)
                SettingRowDivider()
                SettingToggleRow(title: "Connectivity", isOn: $appState.connectivityEnabled)
            }

            SettingSectionLabel(title: "Information")
            SettingGroup {
                SettingToggleRow(title: "Calendar", isOn: $appState.calendarEnabled)
                SettingRowDivider()
                SettingToggleRow(title: "Weather", isOn: $appState.weatherEnabled)
                SettingRowDivider()
                HStack {
                    Text("Temperature Unit")
                        .font(.system(size: 13))
                    Spacer(minLength: 8)
                    Picker("", selection: $appState.temperatureUnit) {
                        Text("°C").tag(TemperatureUnit.celsius)
                        Text("°F").tag(TemperatureUnit.fahrenheit)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 90)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                SettingRowDivider()
                SettingToggleRow(title: "Notifications", isOn: notificationsEnabledBinding)
                if appState.notificationsEnabled {
                    SettingRowDivider()
                    notificationPermissionRow
                    SettingRowDivider()
                    SettingToggleRow(
                        title: "Show previews",
                        description: "Display sender and message text when available.",
                        isOn: notificationPreviewsBinding
                    )
                    SettingRowDivider()
                    notificationRetentionRow
                    ForEach(NotificationFeedSource.allCases) { source in
                        SettingRowDivider()
                        SettingToggleRow(
                            title: source.title,
                            description: source.description,
                            isOn: notificationSourceBinding(for: source)
                        )
                    }
                }
            }

            SettingSectionLabel(title: "Productivity")
            SettingGroup {
                SettingToggleRow(title: "Teleprompter", isOn: $appState.teleprompterEnabled)
                SettingRowDivider()
                HStack {
                    Text("Script")
                        .font(.system(size: 13))
                    Spacer(minLength: 8)
                    Button("Edit Script…") {
                        TeleprompterScriptEditorWindowController.show()
                    }
                    .font(.system(size: 12))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear { notificationManager.checkPermission() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            notificationManager.checkPermission()
        }
    }

    private var notificationPermissionRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Permission")
                    .font(.system(size: 13))
                Text(notificationPermissionDescription)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(notificationPermissionButtonTitle) {
                handleNotificationPermissionAction()
            }
            .font(.system(size: 12))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var notificationRetentionRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Retained items")
                    .font(.system(size: 13))
                Text("How many feed items stay available in the island.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 12)
            StepperField(
                value: notificationMaxRetainedBinding,
                step: 1,
                range: 1...50
            ) { "\(Int($0))" }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var notificationPermissionDescription: String {
        switch notificationManager.authorizationStatus {
        case .authorized:
            return "Allowed. SuperIsland can send its own notifications and extension alerts."
        case .denied:
            return "Denied. Open System Settings to allow SuperIsland notifications."
        case .notDetermined:
            return "Not requested. Allow this when you want SuperIsland or extensions to send macOS notifications."
        case .provisional, .ephemeral:
            return "Allowed with limited delivery."
        @unknown default:
            return "Unknown. Check macOS notification settings."
        }
    }

    private var notificationPermissionButtonTitle: String {
        switch notificationManager.authorizationStatus {
        case .notDetermined:
            return "Request"
        default:
            return "Open Settings"
        }
    }

    private var notificationsEnabledBinding: Binding<Bool> {
        Binding(
            get: { appState.notificationsEnabled },
            set: { newValue in
                appState.notificationsEnabled = newValue
                guard newValue else {
                    NotificationManager.shared.clearAll()
                    return
                }

                NotificationManager.shared.checkPermission()
                if NotificationManager.shared.authorizationStatus == .notDetermined {
                    NotificationManager.shared.requestPermission()
                }
            }
        )
    }

    private var notificationPreviewsBinding: Binding<Bool> {
        Binding(
            get: { appState.notificationPreviewsEnabled },
            set: { newValue in
                appState.notificationPreviewsEnabled = newValue
                NotificationManager.shared.applyFeedPreferences()
            }
        )
    }

    private var notificationMaxRetainedBinding: Binding<Double> {
        Binding(
            get: { appState.notificationMaxRetainedItems },
            set: { newValue in
                appState.notificationMaxRetainedItems = newValue
                NotificationManager.shared.applyFeedPreferences()
            }
        )
    }

    private func notificationSourceBinding(for source: NotificationFeedSource) -> Binding<Bool> {
        Binding(
            get: { appState.isNotificationSourceEnabled(source) },
            set: { newValue in
                appState.setNotificationSource(source, enabled: newValue)
                NotificationManager.shared.applyFeedPreferences()
            }
        )
    }

    private func handleNotificationPermissionAction() {
        switch notificationManager.authorizationStatus {
        case .notDetermined:
            notificationManager.requestPermission()
        default:
            notificationManager.openNotificationSettings()
        }
    }
}
