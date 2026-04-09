import SwiftUI

struct AdvancedSettingsView: View {
    @State private var showResetAlert = false
    @ObservedObject private var updateChecker = UpdateChecker.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            SettingSectionLabel(title: "Debug")
            SettingGroup {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reset All Settings").font(.system(size: 13))
                        Text("Restore all settings to their defaults")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Reset") {
                        showResetAlert = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .alert("Reset Settings", isPresented: $showResetAlert) {
                        Button("Cancel", role: .cancel) {}
                        Button("Reset", role: .destructive) { resetAllSettings() }
                    } message: {
                        Text("This will reset all SuperIsland settings to their defaults.")
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }

            SettingSectionLabel(title: "About")
            SettingGroup {
                HStack {
                    Text("Version").font(.system(size: 13))
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16).padding(.vertical, 11)

                SettingRowDivider()

                HStack {
                    Text("Build").font(.system(size: 13))
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16).padding(.vertical, 11)

                SettingRowDivider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Updates").font(.system(size: 13))
                        updateStatusText
                    }
                    Spacer()
                    updateButton
                }
                .padding(.horizontal, 16).padding(.vertical, 11)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var updateStatusText: some View {
        switch updateChecker.checkState {
        case .idle:
            EmptyView()
        case .checking:
            Text("Checking...").font(.system(size: 11)).foregroundColor(.secondary)
        case .upToDate:
            Text("You're up to date").font(.system(size: 11)).foregroundColor(.green)
        case .updateAvailable(let version, _, _):
            Text("Version \(version) available").font(.system(size: 11)).foregroundColor(.orange)
        case .failed(let message):
            Text(message).font(.system(size: 11)).foregroundColor(.red)
        }
    }

    @ViewBuilder
    private var updateButton: some View {
        switch updateChecker.checkState {
        case .checking:
            ProgressView().controlSize(.small)
        case .updateAvailable(let version, let releaseURL, let downloadURL):
            Button("Update") {
                if let downloadURL {
                    AutoUpdater.shared.start(downloadURL: downloadURL, releaseURL: releaseURL)
                } else {
                    NSWorkspace.shared.open(releaseURL)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        default:
            Button("Check for Updates") { updateChecker.checkNow() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private func resetAllSettings() {
        let domain = Bundle.main.bundleIdentifier ?? "com.workview.SuperIsland"
        UserDefaults.standard.removePersistentDomain(forName: domain)
        UserDefaults.standard.synchronize()
    }
}
