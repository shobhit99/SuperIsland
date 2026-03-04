import Foundation
import Combine

@MainActor
final class ExtensionManager: ObservableObject {
    static let shared = ExtensionManager()

    @Published private(set) var installed: [ExtensionManifest] = []
    @Published private(set) var runtimes: [String: ExtensionJSRuntime] = [:]
    @Published private(set) var extensionStates: [String: ExtensionViewState] = [:]
    @Published private(set) var settingsSchemas: [String: SettingsSchema] = [:]

    let localExtensionsDirectory: URL
    let developmentExtensionsDirectory: URL
    let installedExtensionsDirectory: URL

    var discoveryDirectories: [URL] {
        var paths: [String: URL] = [:]
        for directory in [localExtensionsDirectory, developmentExtensionsDirectory, installedExtensionsDirectory] {
            paths[directory.path] = directory
        }
        return Array(paths.values)
    }

    var availableModules: [ActiveModule] {
        installed
            .filter { runtimes[$0.id] != nil }
            .map { ActiveModule.extension_($0.id) }
    }

    private var refreshTimers: [String: Timer] = [:]
    private let fileManager = FileManager.default

    private init() {
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        localExtensionsDirectory = cwd.appendingPathComponent("Extensions", isDirectory: true)
        developmentExtensionsDirectory = cwd.appendingPathComponent("ExtensionsDev", isDirectory: true)

        let appSupportBase = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        installedExtensionsDirectory = appSupportBase
            .appendingPathComponent("DynamicIsland", isDirectory: true)
            .appendingPathComponent("Extensions", isDirectory: true)

        try? fileManager.createDirectory(at: installedExtensionsDirectory, withIntermediateDirectories: true)
    }

    func discoverExtensions() {
        var discovered: [String: ExtensionManifest] = [:]
        var discoveredSchemas: [String: SettingsSchema] = [:]

        for directory in discoveryDirectories {
            guard fileManager.fileExists(atPath: directory.path) else {
                continue
            }

            let manifests = loadManifests(in: directory)
            for manifest in manifests {
                if discovered[manifest.id] == nil {
                    discovered[manifest.id] = manifest
                } else {
                    ExtensionLogger.shared.log(
                        manifest.id,
                        .warning,
                        "Duplicate extension ID found in discovery paths; keeping first instance"
                    )
                }

                if let settingsURL = manifest.settingsURL,
                   let schema = try? SettingsSchema.load(from: settingsURL) {
                    discoveredSchemas[manifest.id] = schema
                }
            }
        }

        let manifests = discovered.values.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        installed = manifests
        settingsSchemas = discoveredSchemas

        // Deactivate runtimes that are no longer present.
        let activeIDs = Set(runtimes.keys)
        let discoveredIDs = Set(manifests.map(\.id))
        let removedIDs = activeIDs.subtracting(discoveredIDs)
        for id in removedIDs {
            deactivate(extensionID: id)
        }
    }

    func activateDiscoveredExtensions() {
        for manifest in installed {
            activate(extensionID: manifest.id)
        }
    }

    func activate(extensionID: String) {
        guard runtimes[extensionID] == nil else { return }
        guard let manifest = installed.first(where: { $0.id == extensionID }) else { return }

        do {
            let runtime = try ExtensionJSRuntime(manifest: manifest, manager: self)
            runtimes[extensionID] = runtime
            runtime.activate()

            startRefreshTimer(for: manifest)
            refreshState(extensionID: extensionID)

            ExtensionLogger.shared.log(extensionID, .info, "Activated extension")
        } catch {
            ExtensionLogger.shared.log(extensionID, .error, error.localizedDescription)
        }
    }

    func reload(extensionID: String) {
        deactivate(extensionID: extensionID)
        activate(extensionID: extensionID)
    }

    func deactivate(extensionID: String) {
        stopRefreshTimer(for: extensionID)
        runtimes[extensionID]?.deactivate()
        runtimes.removeValue(forKey: extensionID)
        extensionStates.removeValue(forKey: extensionID)

        ExtensionLogger.shared.log(extensionID, .info, "Deactivated extension")
    }

    func refreshState(extensionID: String) {
        guard let runtime = runtimes[extensionID] else { return }
        if let state = runtime.fetchState() {
            extensionStates[extensionID] = state
        }
    }

    func handleAction(extensionID: String, actionID: String, value: Any? = nil) {
        runtimes[extensionID]?.handleAction(actionID: actionID, value: value)
        refreshState(extensionID: extensionID)
    }

    func install(from source: URL) throws -> ExtensionManifest {
        var sourceDirectory = source

        if source.pathExtension.lowercased() == "zip" {
            throw ExtensionManifest.ManifestError.invalidSource(source)
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue {
            sourceDirectory = source
        } else {
            throw ExtensionManifest.ManifestError.invalidSource(source)
        }

        let manifest = try ExtensionManifest.load(from: sourceDirectory)
        let destination = installedExtensionsDirectory.appendingPathComponent(manifest.id, isDirectory: true)

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        try fileManager.copyItem(at: sourceDirectory, to: destination)

        discoverExtensions()
        if let installedManifest = installed.first(where: { $0.id == manifest.id }) {
            return installedManifest
        }
        return manifest
    }

    func uninstall(extensionID: String) throws {
        deactivate(extensionID: extensionID)

        let installDirectory = installedExtensionsDirectory.appendingPathComponent(extensionID, isDirectory: true)
        if fileManager.fileExists(atPath: installDirectory.path) {
            try fileManager.removeItem(at: installDirectory)
        }

        discoverExtensions()
    }

    private func loadManifests(in directory: URL) -> [ExtensionManifest] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var manifests: [ExtensionManifest] = []

        for candidate in contents {
            guard isDirectory(candidate) else { continue }
            do {
                let manifest = try ExtensionManifest.load(from: candidate)
                manifests.append(manifest)
            } catch {
                ExtensionLogger.shared.log(candidate.lastPathComponent, .error, error.localizedDescription)
            }
        }

        return manifests
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    private func startRefreshTimer(for manifest: ExtensionManifest) {
        stopRefreshTimer(for: manifest.id)

        let timer = Timer.scheduledTimer(withTimeInterval: max(0.1, manifest.refreshInterval), repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshState(extensionID: manifest.id)
            }
        }

        RunLoop.main.add(timer, forMode: .common)
        refreshTimers[manifest.id] = timer
    }

    private func stopRefreshTimer(for extensionID: String) {
        refreshTimers[extensionID]?.invalidate()
        refreshTimers.removeValue(forKey: extensionID)
    }
}
