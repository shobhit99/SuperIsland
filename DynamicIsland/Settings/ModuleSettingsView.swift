import SwiftUI

struct ModuleSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section("Media & HUD") {
                Toggle("Now Playing", isOn: $appState.nowPlayingEnabled)
                Toggle("Volume HUD", isOn: $appState.volumeHUDEnabled)
                Toggle("Brightness HUD", isOn: $appState.brightnessHUDEnabled)
            }

            Section("System") {
                Toggle("Battery", isOn: $appState.batteryEnabled)
                Toggle("Connectivity", isOn: $appState.connectivityEnabled)
            }

            Section("Information") {
                Toggle("Calendar", isOn: $appState.calendarEnabled)
                Toggle("Weather", isOn: $appState.weatherEnabled)
                Toggle("Notifications", isOn: $appState.notificationsEnabled)
            }

        }
        .formStyle(.grouped)
        .padding()
    }
}
