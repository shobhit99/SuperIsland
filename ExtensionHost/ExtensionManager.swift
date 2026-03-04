import Foundation

@MainActor
final class ExtensionManager: ObservableObject {
    static let shared = ExtensionManager()

    @Published private(set) var installed: [ExtensionManifest] = []
    @Published private(set) var runtimes: [String: ExtensionJSRuntime] = [:]
    @Published private(set) var extensionStates: [String: ExtensionViewState] = [:]
    @Published private(set) var settingsSchemas: [String: ExtensionSettingsSchema] = [:]

    let extensionsDirectory: URL
    let developmentExtensionsDirectory: URL
    let localExtensionsDirectory: URL

    private var refreshTimers: [String: Timer] = [:]
    private let fileManager = FileManager.default

    private init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        extensionsDirectory = appSupport
            .appending(path: "DynamicIsland", directoryHint: .isDirectory)
            .appending(path: "Extensions", directoryHint: .isDirectory)
        developmentExtensionsDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appending(path: "Extensions", directoryHint: .isDirectory)
        localExtensionsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Extensions", directoryHint: .isDirectory)

        try? fileManager.createDirectory(at: extensionsDirectory, withIntermediateDirectories: true)
    }

    var discoveryDirectories: [URL] {
        var directories: [URL] = []
        for directory in [localExtensionsDirectory, developmentExtensionsDirectory, extensionsDirectory] {
            if !directories.contains(where: { $0.path == directory.path }) {
                directories.append(directory)
            }
        }
        return directories
    }

    func discoverExtensions() {
        var manifests: [ExtensionManifest] = []
        var schemas: [String: ExtensionSettingsSchema] = [:]
        var seen = Set<String>()

        for directory in discoveryDirectories where fileManager.fileExists(atPath: directory.path) {
            let discovered = discoverExtensions(in: directory)
            for manifest in discovered where seen.insert(manifest.id).inserted {
                manifests.append(manifest)
                if let schema = loadSettingsSchema(for: manifest) {
                    schemas[manifest.id] = schema
                }
            }
        }

        installed = manifests.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        settingsSchemas = schemas
    }

    func activateDiscoveredExtensions() {
        installed.forEach { activate(extensionID: $0.id) }
    }

    func manifest(for extensionID: String) -> ExtensionManifest? {
        installed.first { $0.id == extensionID }
    }

    var availableModules: [ActiveModule] {
        installed
            .filter { runtimes[$0.id] != nil }
            .map { .extension_($0.id) }
    }

    func activate(extensionID: String) {
        guard runtimes[extensionID] == nil,
              let manifest = manifest(for: extensionID) else {
            return
        }

        do {
            let runtime = try ExtensionJSRuntime(manifest: manifest)
            runtimes[extensionID] = runtime
            refreshState(extensionID: extensionID)
            startRefreshTimer(for: extensionID, interval: manifest.effectiveRefreshInterval)
            ExtensionLogger.shared.log(extensionID, .info, "Activated \(manifest.name)")
        } catch {
            ExtensionLogger.shared.log(extensionID, .error, error.localizedDescription)
        }
    }

    func deactivate(extensionID: String) {
        refreshTimers[extensionID]?.invalidate()
        refreshTimers.removeValue(forKey: extensionID)
        runtimes[extensionID]?.cleanup()
        runtimes.removeValue(forKey: extensionID)
        extensionStates.removeValue(forKey: extensionID)
    }

    func reload(extensionID: String) {
        deactivate(extensionID: extensionID)
        discoverExtensions()
        activate(extensionID: extensionID)
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
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ExtensionInstallError.unsupportedSource
        }

        let manifest = try ExtensionManifest.load(from: source)
        let destination = extensionsDirectory.appending(path: manifest.id, directoryHint: .isDirectory)

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)

        discoverExtensions()
        activate(extensionID: manifest.id)
        return try ExtensionManifest.load(from: destination)
    }

    func uninstall(extensionID: String) throws {
        guard let manifest = manifest(for: extensionID) else { return }
        deactivate(extensionID: extensionID)

        if manifest.bundleURL.path.hasPrefix(extensionsDirectory.path) {
            try fileManager.removeItem(at: manifest.bundleURL)
        }

        installed.removeAll { $0.id == extensionID }
        settingsSchemas.removeValue(forKey: extensionID)
    }

    func settingValue(for extensionID: String, key: String) -> Any? {
        UserDefaults.standard.object(forKey: settingsKey(extensionID: extensionID, key: key))
    }

    func setSettingValue(_ value: Any?, for extensionID: String, key: String) {
        UserDefaults.standard.set(value, forKey: settingsKey(extensionID: extensionID, key: key))
        refreshState(extensionID: extensionID)
    }

    private func settingsKey(extensionID: String, key: String) -> String {
        "extension.settings.\(extensionID).\(key)"
    }

    private func startRefreshTimer(for extensionID: String, interval: TimeInterval) {
        refreshTimers[extensionID]?.invalidate()
        refreshTimers[extensionID] = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshState(extensionID: extensionID)
            }
        }
    }

    private func discoverExtensions(in directory: URL) -> [ExtensionManifest] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents.compactMap { candidate in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  fileManager.fileExists(atPath: candidate.appending(path: "manifest.json").path) else {
                return nil
            }

            return try? ExtensionManifest.load(from: candidate)
        }
    }

    private func loadSettingsSchema(for manifest: ExtensionManifest) -> ExtensionSettingsSchema? {
        guard fileManager.fileExists(atPath: manifest.settingsURL.path),
              let data = try? Data(contentsOf: manifest.settingsURL) else {
            return nil
        }

        return try? JSONDecoder().decode(ExtensionSettingsSchema.self, from: data)
    }
}
