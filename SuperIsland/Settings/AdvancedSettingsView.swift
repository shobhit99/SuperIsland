import SwiftUI

struct AdvancedSettingsView: View {
    @State private var showResetAlert = false
    @State private var screenOptions: [ScreenDetector.ScreenOption] = ScreenDetector.availableScreenOptions()
    @ObservedObject private var updateChecker = UpdateChecker.shared
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // ── Display ────────────────────────────────────────────────────
            SettingSectionLabel(title: "Display")
            SettingGroup {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show island on").font(.system(size: 13))
                        Text("Pick a specific display or let SuperIsland choose")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Spacer(minLength: 8)
                    Picker("", selection: $appState.displayIdentifier) {
                        ForEach(screenOptions) { option in
                            Text(option.name).tag(option.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 240)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
            }
            .onAppear { refreshScreenOptions() }
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didChangeScreenParametersNotification
            )) { _ in refreshScreenOptions() }

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

    private func refreshScreenOptions() {
        screenOptions = ScreenDetector.availableScreenOptions()
        // If the stored display identifier no longer matches a connected
        // screen (e.g. the user unplugged it), fall back to Automatic.
        let currentID = appState.displayIdentifier
        if !currentID.isEmpty, !screenOptions.contains(where: { $0.id == currentID }) {
            appState.displayIdentifier = ""
        }
    }
}
