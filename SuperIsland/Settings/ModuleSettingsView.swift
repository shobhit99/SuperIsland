import SwiftUI

struct ModuleSettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var extensionManager = ExtensionManager.shared

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
                SettingToggleRow(title: "Notifications", isOn: $appState.notificationsEnabled)
            }

            SettingSectionLabel(title: "Home")
            SettingGroup {
                HomeWidgetPickerRow(
                    title: "Left widget",
                    selection: $appState.homeLeadingWidget,
                    options: appState.homeWidgetOptions
                )
                SettingRowDivider()
                HomeWidgetPickerRow(
                    title: "Center widget",
                    selection: $appState.homeCenterWidget,
                    options: appState.homeWidgetOptions
                )
                SettingRowDivider()
                HomeWidgetPickerRow(
                    title: "Right widget",
                    selection: $appState.homeTrailingWidget,
                    options: appState.homeWidgetOptions
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct HomeWidgetPickerRow: View {
    let title: String
    @Binding var selection: HomeWidgetSelection
    let options: [HomeWidgetOption]

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))

                Text(currentSelectionSubtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Picker("", selection: $selection) {
                ForEach(options) { option in
                    Label(option.label, systemImage: option.iconName)
                        .tag(option.selection)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 180, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var currentSelectionSubtitle: String {
        options.first(where: { $0.selection == selection })?.label ?? selection.displayName
    }
}
