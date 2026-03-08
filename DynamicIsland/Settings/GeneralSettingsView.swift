import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SettingsCard(
                    title: "Startup",
                    subtitle: "Control launch behavior and menu bar visibility."
                ) {
                    Toggle("Launch at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, newValue in
                            if newValue {
                                LaunchAtLogin.enable()
                            } else {
                                LaunchAtLogin.disable()
                            }
                        }

                    Divider().opacity(0.2)
                    Toggle("Show menu bar icon", isOn: $appState.showMenuBarIcon)

                    Divider().opacity(0.2)
                    Toggle("Show in screen recordings", isOn: $appState.showInScreenRecordings)
                }

                SettingsCard(
                    title: "Display",
                    subtitle: "Tune how Dynamic Island appears and animates."
                ) {
                    Toggle("Show on all Spaces", isOn: $appState.showOnAllSpaces)

                    Divider().opacity(0.2)
                    Picker("Animation speed", selection: $appState.animationSpeed) {
                        Text("Normal").tag(1.0)
                        Text("Reduced").tag(1.5)
                        Text("Minimal").tag(2.0)
                    }
                    .pickerStyle(.menu)
                }

                SettingsCard(
                    title: "Behavior",
                    subtitle: "Adjust how long expanded content remains visible."
                ) {
                    HStack {
                        Text("Expanded collapse delay")
                        Slider(value: $appState.expandedAutoDismissDelay, in: 0.5...10.0, step: 0.5)
                        Text("\(appState.expandedAutoDismissDelay, specifier: "%.1f")s")
                            .frame(width: 44)
                            .monospacedDigit()
                    }
                }

                SettingsCard(
                    title: "Interaction",
                    subtitle: "Tune pointer feedback when entering the notch."
                ) {
                    HStack {
                        Text("Notch haptic intensity")
                        Spacer()
                        Picker("", selection: $appState.notchHapticIntensity) {
                            ForEach(NotchHapticIntensity.allCases) { intensity in
                                Text(intensity.title).tag(intensity.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 140)
                    }

                    Text("Higher levels use a stronger multi-pulse haptic when the pointer enters the notch.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                SettingsCard(
                    title: "Permissions",
                    subtitle: "System permissions required for full functionality."
                ) {
                    HStack {
                        Text("Accessibility")
                        Spacer()
                        if PermissionsManager.shared.checkAccessibility() {
                            Label("Granted", systemImage: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        } else {
                            Button("Grant Access") {
                                PermissionsManager.shared.requestAccessibility()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
    }
}
