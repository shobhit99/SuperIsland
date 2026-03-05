import SwiftUI

struct AdvancedSettingsView: View {
    @State private var showResetAlert = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SettingsCard(
                    title: "Debug",
                    subtitle: "Administrative actions for local state."
                ) {
                    Button("Reset All Settings") {
                        showResetAlert = true
                    }
                    .buttonStyle(.bordered)
                    .alert("Reset Settings", isPresented: $showResetAlert) {
                        Button("Cancel", role: .cancel) {}
                        Button("Reset", role: .destructive) {
                            resetAllSettings()
                        }
                    } message: {
                        Text("This will reset all DynamicIsland settings to their defaults.")
                    }
                }

                SettingsCard(
                    title: "About",
                    subtitle: "Application build metadata."
                ) {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                            .foregroundColor(.secondary)
                    }

                    Divider().opacity(0.2)
                    HStack {
                        Text("Build")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
    }

    private func resetAllSettings() {
        let domain = Bundle.main.bundleIdentifier ?? "com.workview.DynamicIsland"
        UserDefaults.standard.removePersistentDomain(forName: domain)
        UserDefaults.standard.synchronize()
    }
}
