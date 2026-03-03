import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        if newValue {
                            LaunchAtLogin.enable()
                        } else {
                            LaunchAtLogin.disable()
                        }
                    }

                Toggle("Show menu bar icon", isOn: $appState.showMenuBarIcon)
            }

            Section("Display") {
                Toggle("Show on all Spaces", isOn: $appState.showOnAllSpaces)

                Picker("Animation speed", selection: $appState.animationSpeed) {
                    Text("Normal").tag(1.0)
                    Text("Reduced").tag(1.5)
                    Text("Minimal").tag(2.0)
                }
            }

            Section("Behavior") {
                HStack {
                    Text("Expanded collapse delay")
                    Slider(value: $appState.expandedAutoDismissDelay, in: 0.5...10.0, step: 0.5)
                    Text("\(appState.expandedAutoDismissDelay, specifier: "%.1f")s")
                        .frame(width: 44)
                }
            }

            Section("Permissions") {
                HStack {
                    Text("Accessibility")
                    Spacer()
                    if PermissionsManager.shared.checkAccessibility() {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Button("Grant Access") {
                            PermissionsManager.shared.requestAccessibility()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
