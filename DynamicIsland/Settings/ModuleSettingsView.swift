import SwiftUI

struct ModuleSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SettingsCard(
                    title: "Media & HUD",
                    subtitle: "Controls for playback and quick hardware overlays."
                ) {
                    Toggle("Now Playing", isOn: $appState.nowPlayingEnabled)
                    Toggle("Volume HUD", isOn: $appState.volumeHUDEnabled)
                    Toggle("Brightness HUD", isOn: $appState.brightnessHUDEnabled)
                }

                SettingsCard(
                    title: "System",
                    subtitle: "Status modules for power and connectivity."
                ) {
                    Toggle("Battery", isOn: $appState.batteryEnabled)
                    Toggle("Connectivity", isOn: $appState.connectivityEnabled)
                }

                SettingsCard(
                    title: "Information",
                    subtitle: "Calendar, weather, and notification surface modules."
                ) {
                    Toggle("Calendar", isOn: $appState.calendarEnabled)
                    Toggle("Weather", isOn: $appState.weatherEnabled)
                    Toggle("Notifications", isOn: $appState.notificationsEnabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}
