import AppKit
import SwiftUI

private struct MascotGridPicker: View {
    @ObservedObject private var manager = MascotManager.shared
    @State private var downloadingSlug: String?

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 120), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(manager.availableMascots) { entry in
                mascotCell(entry)
            }
        }
    }

    private func mascotCell(_ entry: MascotCatalogEntry) -> some View {
        let isSelected = manager.selectedSlug == entry.slug
        let isDownloaded = manager.isMascotDownloaded(entry.slug)
        let isDownloading = downloadingSlug == entry.slug

        return Button {
            guard !isDownloading else { return }
            if isDownloaded {
                manager.selectMascot(entry.slug)
            } else {
                downloadingSlug = entry.slug
                Task {
                    let didDownload = await manager.downloadMascot(entry.slug)
                    downloadingSlug = nil
                    if didDownload {
                        manager.selectMascot(entry.slug)
                    }
                }
            }
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04))
                        .frame(height: 80)

                    AsyncImage(url: URL(string: entry.thumbnailURL)) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        ProgressView().controlSize(.small)
                    }
                    .frame(width: 60, height: 60)

                    if !isDownloaded {
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                if isDownloading {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .padding(4)
                                } else {
                                    Image(systemName: "arrow.down.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundColor(.accentColor)
                                        .padding(4)
                                }
                            }
                        }
                        .frame(height: 80)
                    }
                }

                Text(entry.name)
                    .font(.caption)
                    .foregroundColor(isSelected ? .accentColor : .primary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                .frame(height: 80)
                .offset(y: -10)
        )
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var mascotManager = MascotManager.shared
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var permissionStates: [PermissionType: Bool] = [:]
    private let permissionRefreshTimer = Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Startup
            SettingSectionLabel(title: "Startup")
            SettingGroup {
                HStack {
                    Text("Launch at login").font(.system(size: 13))
                    Spacer()
                    Toggle("", isOn: $launchAtLogin)
                        .labelsHidden()
                        .onChange(of: launchAtLogin) { _, newValue in
                            newValue ? LaunchAtLogin.enable() : LaunchAtLogin.disable()
                        }
                }
                .padding(.horizontal, 16).padding(.vertical, 11)

                SettingRowDivider()
                SettingToggleRow(title: "Show menu bar icon", isOn: $appState.showMenuBarIcon)
                SettingRowDivider()
                SettingToggleRow(title: "Show in screen recordings", isOn: $appState.showInScreenRecordings)
            }

            // Display
            SettingSectionLabel(title: "Display")
            SettingGroup {
                SettingToggleRow(title: "Show on all Spaces", isOn: $appState.showOnAllSpaces)
                if appState.presentationHasNotch {
                    SettingRowDivider()
                    SettingToggleRow(title: "Hide side slots", isOn: $appState.hideSideSlots)
                } else {
                    SettingRowDivider()
                    SettingToggleRow(title: "Hide on fullscreen", isOn: $appState.hideOnFullscreen)
                }
                SettingRowDivider()
                HStack {
                    Text("Animation Speed").font(.system(size: 13))
                    Spacer()
                    Picker("", selection: $appState.animationSpeed) {
                        Text("Normal").tag(1.0)
                        Text("Reduced").tag(1.5)
                        Text("Minimal").tag(2.0)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 120)
                }
                .padding(.horizontal, 16).padding(.vertical, 11)
            }

            // Behavior
            SettingSectionLabel(title: "Behavior")
            SettingGroup {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Expanded collapse delay").font(.system(size: 13))
                        Text("How long expanded content stays visible")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Spacer(minLength: 12)
                    StepperField(
                        value: $appState.expandedAutoDismissDelay,
                        step: 0.5,
                        range: 0.5...10.0
                    ) { "\(String(format: "%.1f", $0))s" }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }

            // Interaction
            SettingSectionLabel(title: "Interaction")
            SettingGroup {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notch haptic intensity").font(.system(size: 13))
                        Text("Feedback strength when entering the notch")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Spacer(minLength: 12)
                    Picker("", selection: $appState.notchHapticIntensity) {
                        ForEach(NotchHapticIntensity.allCases) { intensity in
                            Text(intensity.title).tag(intensity.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 120)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }

            // Permissions
            SettingSectionLabel(title: "Permissions")
            SettingGroup {
                permissionRow(.accessibility,
                    title: "Accessibility", icon: "figure.stand",
                    description: "Gesture detection and system events")
                SettingRowDivider()
                permissionRow(.calendar,
                    title: "Calendar", icon: "calendar",
                    description: "Show upcoming events in the island")
                SettingRowDivider()
                permissionRow(.location,
                    title: "Location", icon: "location.fill",
                    description: "Weather information for your location")
                SettingRowDivider()
                permissionRow(.bluetooth,
                    title: "Bluetooth", icon: "wave.3.right.circle.fill",
                    description: "Connected device notifications")
            }

            // Mascot
            SettingSectionLabel(title: "Mascot")
            SettingGroup {
                MascotGridPicker()
                    .padding(14)

                if let loadError = mascotManager.loadError {
                    SettingRowDivider()
                    Text(loadError)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }

                SettingRowDivider()
                SettingToggleRow(title: "Show mascot in Pomodoro", isOn: $mascotManager.showInPomodoro)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear { refreshPermissionStates() }
        .onReceive(permissionRefreshTimer) { _ in refreshPermissionStates() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStates()
        }
    }

    @ViewBuilder
    private func permissionRow(
        _ permission: PermissionType,
        title: String, icon: String, description: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(permissionGranted(permission) ? .green : .secondary)
                .frame(width: 18, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                Text(description).font(.system(size: 11)).foregroundColor(.secondary)
            }

            Spacer()

            if permissionGranted(permission) {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.green)
            } else {
                Button("Grant Access") { requestPermission(permission) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func permissionGranted(_ permission: PermissionType) -> Bool {
        permissionStates[permission] ?? false
    }

    private func refreshPermissionStates() {
        permissionStates[.accessibility] = PermissionsManager.shared.checkAccessibility()
        permissionStates[.calendar] = PermissionsManager.shared.checkCalendar()
        permissionStates[.location] = PermissionsManager.shared.checkLocation()
        permissionStates[.bluetooth] = PermissionsManager.shared.checkBluetooth()
    }

    private func requestPermission(_ permission: PermissionType) {
        PermissionsManager.shared.request(permission)
        refreshPermissionStates()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            refreshPermissionStates()
            try? await Task.sleep(nanoseconds: 900_000_000)
            refreshPermissionStates()
        }
    }
}
