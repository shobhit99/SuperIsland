import SwiftUI

struct ModuleSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            SettingSectionLabel(title: "Media & HUD")
            SettingGroup {
                SettingToggleRow(title: "Now Playing", isOn: $appState.nowPlayingEnabled)
                SettingRowDivider()
                SettingToggleRow(title: "Volume HUD", isOn: $appState.volumeHUDEnabled)
            }

            SettingSectionLabel(title: "Home")
            SettingGroup {
                homeSlotRow(title: "Left slot", selection: $appState.homeLeadingPanelRaw)
                SettingRowDivider()
                homeSlotRow(title: "Center slot", selection: $appState.homeCenterPanelRaw)
                SettingRowDivider()
                homeSlotRow(title: "Right slot", selection: $appState.homeTrailingPanelRaw)
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

    private func homeSlotRow(title: String, selection: Binding<String>) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
            Spacer(minLength: 12)
            Picker("", selection: selection) {
                ForEach(HomePanel.allCases) { panel in
                    Label(panel.title, systemImage: panel.iconName)
                        .tag(panel.rawValue)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 150)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}
