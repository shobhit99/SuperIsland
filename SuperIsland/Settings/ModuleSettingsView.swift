import SwiftUI

struct ModuleSettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var nowPlayingManager = NowPlayingManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            SettingSectionLabel(title: "Media & HUD")
            SettingGroup {
                SettingToggleRow(title: "Now Playing", isOn: $appState.nowPlayingEnabled)
                if appState.nowPlayingEnabled {
                    SettingRowDivider()
                    SettingToggleRow(
                        title: "Browser media detection",
                        description: "Use macOS automation to detect media in allowed browsers.",
                        isOn: $nowPlayingManager.browserDetectionEnabled
                    )
                    if nowPlayingManager.browserDetectionEnabled {
                        browserMediaRows
                    }
                }
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
                SettingToggleRow(title: "Notifications", isOn: $appState.notificationsEnabled)
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
    }

    @ViewBuilder
    private var browserMediaRows: some View {
        ForEach(nowPlayingManager.browserTargets) { browser in
            SettingRowDivider()
            browserToggleRow(browser)
        }
        SettingRowDivider()
        browserDetectionTestRow
    }

    private func browserToggleRow(_ browser: NowPlayingBrowserTarget) -> some View {
        SettingToggleRow(
            title: browser.displayName,
            description: "Allow SuperIsland to look for media in this browser.",
            isOn: browserBinding(for: browser.id)
        )
    }

    private var browserDetectionTestRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Detection test")
                    .font(.system(size: 13))
                Text(browserDetectionMessage)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                Button("Test") {
                    nowPlayingManager.testBrowserDetection()
                }
                .font(.system(size: 12))
                Button("Open Settings") {
                    nowPlayingManager.openAutomationSettings()
                }
                .font(.system(size: 12))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func browserBinding(for browserID: String) -> Binding<Bool> {
        Binding(
            get: { nowPlayingManager.isBrowserAllowed(browserID) },
            set: { nowPlayingManager.setBrowser(browserID, allowed: $0) }
        )
    }

    private var browserDetectionMessage: String {
        if !nowPlayingManager.browserDetectionTestMessage.isEmpty {
            return nowPlayingManager.browserDetectionTestMessage
        }
        return "Requires Automation permission and JavaScript from Apple Events in the browser."
    }
}
