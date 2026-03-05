import SwiftUI
import AppKit

private enum ExtensionListFilter: String, CaseIterable, Identifiable {
    case all
    case installed
    case active

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .installed: return "Installed"
        case .active: return "Active"
        }
    }
}

struct ExtensionsSettingsView: View {
    @ObservedObject private var manager = ExtensionManager.shared
    @ObservedObject private var logger = ExtensionLogger.shared
    @State private var selectedExtensionID: String?
    @State private var listFilter: ExtensionListFilter = .all

    var body: some View {
        HStack(spacing: 10) {
            leftPane
                .frame(width: 300)

            rightPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            manager.discoverExtensions()
            preserveSelection()
        }
        .onChange(of: manager.installed.map(\.id)) { _, _ in
            preserveSelection()
        }
        .onChange(of: activeExtensionIDs) { _, _ in
            preserveSelection()
        }
        .onChange(of: listFilter) { _, _ in
            preserveSelection()
        }
    }

    private var leftPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Extensions")
                    .font(.headline.weight(.semibold))

                Spacer()

                Button {
                    manager.discoverExtensions()
                    preserveSelection()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Picker("Filter", selection: $listFilter) {
                ForEach(ExtensionListFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)

            Text("\(filteredManifests.count) shown")
                .font(.caption)
                .foregroundColor(.secondary)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(filteredManifests, id: \.id) { manifest in
                        let isSelected = selectedExtensionID == manifest.id
                        Button {
                            selectedExtensionID = manifest.id
                        } label: {
                            extensionListRow(for: manifest, isSelected: isSelected)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .panelBackground()
    }

    @ViewBuilder
    private var rightPane: some View {
        if let manifest = selectedManifest {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    extensionHeaderCard(for: manifest)

                    SettingsCard(title: "Details") {
                        if let author = manifest.author?.name {
                            metadataRow(label: "Author", value: author)
                        }
                        metadataRow(label: "Refresh", value: "\(String(format: "%.1f", manifest.refreshInterval))s")
                        metadataRow(label: "Triggers", value: manifest.activationTriggers.joined(separator: ", "))

                        if !manifest.permissions.isEmpty {
                            metadataRow(label: "Permissions", value: manifest.permissions.joined(separator: ", "))
                        }
                    }

                    if let schema = manager.settingsSchemas[manifest.id] {
                        SettingsCard(title: "Settings") {
                            ExtensionSettingsRenderer(extensionID: manifest.id, schema: schema)
                        }
                    }

                    let logEntries = logger.entries(for: manifest.id)
                    if !logEntries.isEmpty {
                        SettingsCard(title: "Recent Logs") {
                            VStack(alignment: .leading, spacing: 7) {
                                ForEach(logEntries.suffix(8)) { entry in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(.secondary)
                                            .frame(width: 72, alignment: .leading)

                                        Text("[\(entry.level.rawValue.uppercased())] \(entry.message)")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(entry.level == .error ? .red : .secondary)
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 4)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 28))
                    .foregroundColor(.secondary)
                Text("Select an extension")
                    .font(.headline)
                Text("Choose an extension from the left panel.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .panelBackground()
        }
    }

    private func extensionHeaderCard(for manifest: ExtensionManifest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                HStack(alignment: .top, spacing: 10) {
                    extensionIcon(for: manifest, size: 36)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(manifest.name)
                            .font(.title3.weight(.semibold))
                        Text("\(manifest.id) • v\(manifest.version)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Text(manager.runtimes[manifest.id] == nil ? "Inactive" : "Active")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(manager.runtimes[manifest.id] == nil ? Color.secondary.opacity(0.15) : Color.green.opacity(0.15))
                    )
                    .foregroundColor(manager.runtimes[manifest.id] == nil ? .secondary : .green)
            }

            Text(manifest.description)
                .font(.body)
                .foregroundColor(.secondary)

            HStack(spacing: 10) {
                Button(manager.runtimes[manifest.id] == nil ? "Activate" : "Reload") {
                    if manager.runtimes[manifest.id] == nil {
                        manager.activate(extensionID: manifest.id)
                    } else {
                        manager.reload(extensionID: manifest.id)
                    }
                }
                .buttonStyle(.borderedProminent)

                if manager.runtimes[manifest.id] != nil {
                    Button("Deactivate") {
                        manager.deactivate(extensionID: manifest.id)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(10)
        .panelBackground()
    }

    private func extensionListRow(for manifest: ExtensionManifest, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            extensionIcon(for: manifest, size: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(manifest.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)

                    sourceBadge(for: manifest)
                }

                Text(manifest.id)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
                    .foregroundColor(isSelected ? .white.opacity(0.85) : .secondary)
            }

            Spacer(minLength: 6)

            Circle()
                .fill(manager.runtimes[manifest.id] == nil ? Color.secondary.opacity(isSelected ? 0.75 : 0.45) : Color.green)
                .frame(width: 7, height: 7)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .foregroundColor(isSelected ? .white : .primary)
    }

    @ViewBuilder
    private func sourceBadge(for manifest: ExtensionManifest) -> some View {
        let source = extensionSource(for: manifest)
        Text(source.label)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(source.color.opacity(0.15))
            )
            .foregroundColor(source.color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func extensionIcon(for manifest: ExtensionManifest, size: CGFloat) -> some View {
        if let image = extensionIconImage(for: manifest) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: max(5, size * 0.22), style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: max(5, size * 0.22), style: .continuous)
                        .stroke(Color.secondary.opacity(0.24), lineWidth: 0.6)
                )
        } else {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: size * 0.52, weight: .semibold))
                .foregroundColor(.accentColor)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: max(5, size * 0.22), style: .continuous)
                        .fill(Color.accentColor.opacity(0.16))
                )
        }
    }

    private func extensionIconImage(for manifest: ExtensionManifest) -> NSImage? {
        guard let iconURL = manifest.iconURL else { return nil }

        if let image = NSImage(contentsOf: iconURL) {
            return image
        }

        if let data = try? Data(contentsOf: iconURL), let image = NSImage(data: data) {
            return image
        }

        return nil
    }

    private func metadataRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private var selectedManifest: ExtensionManifest? {
        guard let selectedExtensionID else { return nil }
        return filteredManifests.first(where: { $0.id == selectedExtensionID })
            ?? manager.installed.first(where: { $0.id == selectedExtensionID })
    }

    private var filteredManifests: [ExtensionManifest] {
        switch listFilter {
        case .all:
            return manager.installed
        case .installed:
            return manager.installed.filter(isInstalledExtension)
        case .active:
            return manager.installed.filter { manager.runtimes[$0.id] != nil }
        }
    }

    private var activeExtensionIDs: [String] {
        manager.runtimes.keys.sorted()
    }

    private func extensionSource(for manifest: ExtensionManifest) -> (label: String, color: Color) {
        if isInstalledExtension(manifest) {
            return ("Installed", .blue)
        }
        return ("Bundled", .secondary)
    }

    private func isInstalledExtension(_ manifest: ExtensionManifest) -> Bool {
        let installedPath = manager.installedExtensionsDirectory.standardizedFileURL.path
        let bundlePath = manifest.bundleURL.standardizedFileURL.path
        return bundlePath == installedPath || bundlePath.hasPrefix(installedPath + "/")
    }

    private func preserveSelection() {
        guard !filteredManifests.isEmpty else {
            selectedExtensionID = nil
            return
        }

        if let selectedExtensionID,
           filteredManifests.contains(where: { $0.id == selectedExtensionID }) {
            return
        }

        selectedExtensionID = filteredManifests.first?.id
    }
}

private extension View {
    func panelBackground() -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.8))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }
}
