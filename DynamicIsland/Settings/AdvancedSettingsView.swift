import SwiftUI

struct AdvancedSettingsView: View {
    @State private var showResetAlert = false
    @ObservedObject private var updateChecker = UpdateChecker.shared

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

                    Divider().opacity(0.2)
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Updates")
                            updateStatusText
                        }
                        Spacer()
                        updateButton
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var updateStatusText: some View {
        switch updateChecker.checkState {
        case .idle:
            EmptyView()
        case .checking:
            Text("Checking...")
                .font(.caption)
                .foregroundColor(.secondary)
        case .upToDate:
            Text("You're up to date")
                .font(.caption)
                .foregroundColor(.green)
        case .updateAvailable(let version, _):
            Text("Version \(version) available")
                .font(.caption)
                .foregroundColor(.orange)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundColor(.red)
        }
    }

    @ViewBuilder
    private var updateButton: some View {
        switch updateChecker.checkState {
        case .checking:
            ProgressView()
                .controlSize(.small)
        case .updateAvailable(_, let url):
            Button("Download") {
                NSWorkspace.shared.open(url)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        default:
            Button("Check for Updates") {
                updateChecker.checkNow()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func resetAllSettings() {
        let domain = Bundle.main.bundleIdentifier ?? "com.workview.DynamicIsland"
        UserDefaults.standard.removePersistentDomain(forName: domain)
        UserDefaults.standard.synchronize()
    }
}
