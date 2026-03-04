import SwiftUI

struct ExtensionsSettingsView: View {
    @ObservedObject private var manager = ExtensionManager.shared
    @ObservedObject private var logger = ExtensionLogger.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("Sources") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(manager.discoveryDirectories.enumerated()), id: \.offset) { index, directory in
                            Text(sourceLabel(for: directory))
                                .font(.headline)
                            Text(directory.path)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)

                            if index != manager.discoveryDirectories.count - 1 {
                                Divider()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Installed Extensions") {
                    if manager.installed.isEmpty {
                        Text("No extensions discovered yet.")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(manager.installed, id: \.id) { manifest in
                                extensionCard(for: manifest)

                                if manifest.id != manager.installed.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .onAppear {
            manager.discoverExtensions()
        }
    }

    private func sourceLabel(for directory: URL) -> String {
        if directory.path == manager.localExtensionsDirectory.path {
            return "Local Repo"
        }
        if directory.path == manager.developmentExtensionsDirectory.path {
            return "Working Directory"
        }
        return "Installed"
    }

    @ViewBuilder
    private func extensionCard(for manifest: ExtensionManifest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(manifest.name)
                        .font(.headline)
                    Text("\(manifest.id) • v\(manifest.version)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text(manager.runtimes[manifest.id] == nil ? "Inactive" : "Active")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(manager.runtimes[manifest.id] == nil ? .secondary : .green)
            }

            Text(manifest.description)
                .font(.subheadline)
                .foregroundColor(.secondary)

            if !manifest.permissions.isEmpty {
                Text("Permissions: \(manifest.permissions.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 10) {
                Button(manager.runtimes[manifest.id] == nil ? "Activate" : "Reload") {
                    if manager.runtimes[manifest.id] == nil {
                        manager.activate(extensionID: manifest.id)
                    } else {
                        manager.reload(extensionID: manifest.id)
                    }
                }

                if manager.runtimes[manifest.id] != nil {
                    Button("Deactivate") {
                        manager.deactivate(extensionID: manifest.id)
                    }
                }
            }

            if let schema = manager.settingsSchemas[manifest.id] {
                Divider()
                ExtensionSettingsRenderer(extensionID: manifest.id, schema: schema)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            let logEntries = logger.entries(for: manifest.id)
            if !logEntries.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent Logs")
                        .font(.subheadline.weight(.semibold))
                    ForEach(logEntries.suffix(4)) { entry in
                        Text("[\(entry.level.rawValue.uppercased())] \(entry.message)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(entry.level == .error ? .red : .secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
