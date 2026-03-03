import SwiftUI

struct AdvancedSettingsView: View {
    @State private var showResetAlert = false

    var body: some View {
        Form {
            Section("Debug") {
                Button("Reset All Settings") {
                    showResetAlert = true
                }
                .alert("Reset Settings", isPresented: $showResetAlert) {
                    Button("Cancel", role: .cancel) {}
                    Button("Reset", role: .destructive) {
                        resetAllSettings()
                    }
                } message: {
                    Text("This will reset all DynamicIsland settings to their defaults.")
                }
            }

            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Build")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func resetAllSettings() {
        let domain = Bundle.main.bundleIdentifier ?? "com.workview.DynamicIsland"
        UserDefaults.standard.removePersistentDomain(forName: domain)
        UserDefaults.standard.synchronize()
    }
}
