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
                    SettingsPermissionRow(
                        title: "Accessibility",
                        icon: "figure.stand",
                        description: "Gesture detection and system events",
                        isGranted: PermissionsManager.shared.checkAccessibility(),
                        action: { PermissionsManager.shared.requestAccessibility() }
                    )

                    Divider().opacity(0.2)

                    SettingsPermissionRow(
                        title: "Calendar",
                        icon: "calendar",
                        description: "Show upcoming events in the island",
                        isGranted: PermissionsManager.shared.checkCalendar(),
                        action: { Task { _ = await PermissionsManager.shared.requestCalendarAccess() } }
                    )

                    Divider().opacity(0.2)

                    SettingsPermissionRow(
                        title: "Location",
                        icon: "location.fill",
                        description: "Weather information for your location",
                        isGranted: PermissionsManager.shared.checkLocation(),
                        action: { PermissionsManager.shared.requestLocationAccess() }
                    )

                    Divider().opacity(0.2)

                    SettingsPermissionRow(
                        title: "Bluetooth",
                        icon: "wave.3.right.circle.fill",
                        description: "Connected device notifications",
                        isGranted: PermissionsManager.shared.checkBluetooth(),
                        action: { PermissionsManager.shared.openBluetoothSettings() }
                    )
                }

                SettingsCard(
                    title: "Mascot",
                    subtitle: "Choose an animated mascot companion from masko.ai."
                ) {
                    MascotGridPicker()

                    if let loadError = mascotManager.loadError {
                        Divider().opacity(0.2)
                        Text(loadError)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Divider().opacity(0.2)
                    Toggle("Show mascot in Pomodoro", isOn: $mascotManager.showInPomodoro)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
    }
}

private struct SettingsPermissionRow: View {
    let title: String
    let icon: String
    let description: String
    let isGranted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(isGranted ? .green : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isGranted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.green)
            } else {
                Button("Grant Access", action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }
}
