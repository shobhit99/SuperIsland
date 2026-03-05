import SwiftUI

struct ModuleSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SettingsCard(
                    title: "Media & HUD",
                    subtitle: "Controls for playback and quick hardware overlays."
                ) {
                    Toggle("Now Playing", isOn: $appState.nowPlayingEnabled)
                    Divider().opacity(0.2)
                    Toggle("Volume HUD", isOn: $appState.volumeHUDEnabled)
                    Divider().opacity(0.2)
                    Toggle("Brightness HUD", isOn: $appState.brightnessHUDEnabled)
                }

                SettingsCard(
                    title: "System",
                    subtitle: "Status modules for power and connectivity."
                ) {
                    Toggle("Battery", isOn: $appState.batteryEnabled)
                    Divider().opacity(0.2)
                    Toggle("Connectivity", isOn: $appState.connectivityEnabled)
                }

                SettingsCard(
                    title: "Information",
                    subtitle: "Calendar, weather, and notification surface modules."
                ) {
                    Toggle("Calendar", isOn: $appState.calendarEnabled)
                    Divider().opacity(0.2)
                    Toggle("Weather", isOn: $appState.weatherEnabled)
                    Divider().opacity(0.2)
                    Toggle("Notifications", isOn: $appState.notificationsEnabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
    }
}
