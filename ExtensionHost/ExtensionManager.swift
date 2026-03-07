import Foundation
import Combine
import WebKit
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit

@MainActor
final class ExtensionManager: ObservableObject {
    private struct PresentedInteractionContext {
        let returnModule: ActiveModule?
    }

    static let shared = ExtensionManager()

    @Published private(set) var installed: [ExtensionManifest] = []
    @Published private(set) var runtimes: [String: ExtensionJSRuntime] = [:]
    @Published private(set) var extensionStates: [String: ExtensionViewState] = [:]
    @Published private(set) var settingsSchemas: [String: SettingsSchema] = [:]

    let localExtensionsDirectory: URL
    let developmentExtensionsDirectory: URL
    let installedExtensionsDirectory: URL
    private let fallbackRepoExtensionsDirectory: URL?

    var discoveryDirectories: [URL] {
        var paths: [String: URL] = [:]
        for directory in [
            fallbackRepoExtensionsDirectory,
            localExtensionsDirectory,
            developmentExtensionsDirectory,
            installedExtensionsDirectory
        ].compactMap({ $0 }) {
            paths[directory.path] = directory
        }
        return Array(paths.values)
    }

    var availableModules: [ActiveModule] {
        installed
            .filter { manifest in
                runtimes[manifest.id] != nil && !manifest.capabilities.notificationFeed
            }
            .map { ActiveModule.extension_($0.id) }
    }

    func isNotificationFeedExtension(_ extensionID: String) -> Bool {
        installed.first(where: { $0.id == extensionID })?.capabilities.notificationFeed == true
    }

    private var refreshTimers: [String: Timer] = [:]
    private var immediateRefreshWorkItems: [String: DispatchWorkItem] = [:]
    private var presentedInteractionContexts: [String: PresentedInteractionContext] = [:]
    private let fileManager = FileManager.default

    private init() {
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        localExtensionsDirectory = cwd.appendingPathComponent("Extensions", isDirectory: true)
        developmentExtensionsDirectory = cwd.appendingPathComponent("ExtensionsDev", isDirectory: true)
        fallbackRepoExtensionsDirectory = Self.resolveRepoExtensionsDirectory()

        let appSupportBase = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        installedExtensionsDirectory = appSupportBase
            .appendingPathComponent("DynamicIsland", isDirectory: true)
            .appendingPathComponent("Extensions", isDirectory: true)

        try? fileManager.createDirectory(at: installedExtensionsDirectory, withIntermediateDirectories: true)
    }

    private static func resolveRepoExtensionsDirectory() -> URL? {
        // In local development builds, #filePath resolves to this source file path.
        // That lets us reliably find "<repo>/Extensions" even if process CWD differs.
        let sourceFileURL = URL(fileURLWithPath: #filePath)
        let extensionHostDirectory = sourceFileURL.deletingLastPathComponent()
        let repoRoot = extensionHostDirectory.deletingLastPathComponent()
        let repoExtensions = repoRoot.appendingPathComponent("Extensions", isDirectory: true)

        if FileManager.default.fileExists(atPath: repoExtensions.path) {
            return repoExtensions
        }
        return nil
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
        immediateRefreshWorkItems[extensionID]?.cancel()
        immediateRefreshWorkItems.removeValue(forKey: extensionID)
        presentedInteractionContexts.removeValue(forKey: extensionID)
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

    func scheduleImmediateRefresh(extensionID: String, delay: TimeInterval = 0.05) {
        guard runtimes[extensionID] != nil else { return }
        guard immediateRefreshWorkItems[extensionID] == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.immediateRefreshWorkItems.removeValue(forKey: extensionID)
            self.refreshState(extensionID: extensionID)
        }

        immediateRefreshWorkItems[extensionID] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: workItem)
    }

    func handleAction(extensionID: String, actionID: String, value: Any? = nil) {
        runtimes[extensionID]?.handleAction(actionID: actionID, value: value)
        refreshState(extensionID: extensionID)
    }

    func presentExtensionInteraction(
        extensionID: String,
        actionID: String,
        value: Any? = nil,
        presentation: NotificationActionPresentation = .fullExpanded,
        returnModule: ActiveModule? = nil
    ) {
        if runtimes[extensionID] == nil {
            activate(extensionID: extensionID)
        }

        presentedInteractionContexts[extensionID] = PresentedInteractionContext(returnModule: returnModule)
        AppState.shared.showHUD(module: .extension_(extensionID), autoDismiss: false)
        if presentation == .fullExpanded {
            AppState.shared.fullyExpand()
            AppState.shared.cancelFullExpandedCollapse()
        }

        handleAction(extensionID: extensionID, actionID: actionID, value: value)
    }

    func closePresentedInteraction(extensionID: String) -> Bool {
        guard let context = presentedInteractionContexts.removeValue(forKey: extensionID),
              let returnModule = context.returnModule else {
            return false
        }

        AppState.shared.setActiveModule(returnModule)
        AppState.shared.cancelFullExpandedCollapse()
        return true
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

        guard manifest.capabilities.backgroundRefresh,
              manifest.activationTriggers.contains(where: { $0.caseInsensitiveCompare("timer") == .orderedSame }) else {
            return
        }

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
struct WhatsAppWebMessage: Identifiable {
    let id: String
    let sender: String
    let preview: String
    let mediaPreviewURL: String?
    let avatarURL: String?
    let replyTarget: String?
    let timestamp: Date
}

private struct PendingWhatsAppProviderCommand {
    let payload: [String: Any]
    let dedupeKey: String?
}

@MainActor
final class WhatsAppWebBridge: ObservableObject {
    static let shared = WhatsAppWebBridge()
    private static let managedExtensionID = "com.workview.whatsapp-web"

    enum ConnectionState: String {
        case idle
        case loading
        case qrReady
        case loggedIn
        case error
    }

    @Published private(set) var connectionState: ConnectionState = .idle
    @Published private(set) var statusText: String = "Not connected"
    @Published private(set) var qrCodeDataURL: String?
    @Published private(set) var lastError: String?
    @Published private(set) var recentMessages: [WhatsAppWebMessage] = []

    private let fileManager = FileManager.default
    private let qrRenderContext = CIContext(options: nil)
    private var providerProcess: Process?
    private var providerInputHandle: FileHandle?
    private var providerOutputHandle: FileHandle?
    private var providerErrorHandle: FileHandle?
    private var providerOutputBuffer = Data()
    private var providerErrorBuffer = Data()
    private var pendingCommands: [PendingWhatsAppProviderCommand] = []
    private var pendingCommandKeys: Set<String> = []
    private var shouldKeepProviderRunning = false
    private var providerReady = false
    private var providerRestartAttempts = 0
    private var providerRestartWorkItem: DispatchWorkItem?
    private var sentCommandSequence = 0
    private var seenMessageIDs: [String] = []
    private let maxSeenMessageIDs = 600
    private var cachedNodeExecutableURL: URL?
    private var pendingAvatarDownloads: Set<String> = []
    private var cachedAvatarFileURLs: [String: String] = [:]

    private init() {}

    private var appSupportDirectory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("DynamicIsland", isDirectory: true)
    }

    private var authDirectory: URL {
        appSupportDirectory
            .appendingPathComponent("WhatsAppWebAuth", isDirectory: true)
            .appendingPathComponent("default", isDirectory: true)
    }

    private var avatarCacheDirectory: URL {
        appSupportDirectory.appendingPathComponent("WhatsAppWebAvatarCache", isDirectory: true)
    }

    private static var providerDirectory: URL {
        let sourceFileURL = URL(fileURLWithPath: #filePath)
        let extensionHostDirectory = sourceFileURL.deletingLastPathComponent()
        let repoRoot = extensionHostDirectory.deletingLastPathComponent()
        return repoRoot.appendingPathComponent("Extensions/whatsapp-web/provider", isDirectory: true)
    }

    private var providerScriptURL: URL {
        Self.providerDirectory.appendingPathComponent("index.mjs", isDirectory: false)
    }

    private var bridgeRefreshSignature: String {
        let messageSignature = recentMessages
            .prefix(8)
            .map {
                "\($0.id)|\($0.sender)|\($0.preview)|\($0.mediaPreviewURL ?? "")|\($0.replyTarget ?? "")|\(Int($0.timestamp.timeIntervalSince1970))"
            }
            .joined(separator: "||")

        return [
            connectionState.rawValue,
            statusText,
            qrCodeDataURL ?? "",
            lastError ?? "",
            messageSignature
        ].joined(separator: "::")
    }

    private func performBridgeUpdate(_ updates: () -> Void) {
        let previousSignature = bridgeRefreshSignature
        updates()
        guard bridgeRefreshSignature != previousSignature else { return }
        ExtensionManager.shared.scheduleImmediateRefresh(extensionID: Self.managedExtensionID)
    }

    func start() {
        shouldKeepProviderRunning = true
        startProviderIfNeeded()
        if providerReady && (connectionState == .idle || connectionState == .error) {
            sendProviderCommand(["command": "start", "requestId": nextRequestID()])
        }
    }

    func refreshQRCode() {
        shouldKeepProviderRunning = true
        performBridgeUpdate {
            connectionState = .loading
            statusText = "Refreshing QR code..."
            qrCodeDataURL = nil
            lastError = nil
            recentMessages.removeAll()
            seenMessageIDs.removeAll()
        }
        startProviderIfNeeded()
        sendProviderCommand(
            ["command": "refreshQR", "requestId": nextRequestID()],
            dedupeKey: "refreshQR"
        )
    }

    func logout() {
        shouldKeepProviderRunning = true
        performBridgeUpdate {
            connectionState = .loading
            statusText = "Logging out..."
            qrCodeDataURL = nil
            lastError = nil
            recentMessages.removeAll()
            seenMessageIDs.removeAll()
        }
        startProviderIfNeeded()
        sendProviderCommand(
            ["command": "logout", "requestId": nextRequestID()],
            dedupeKey: "logout"
        )
    }

    func snapshot(limit: Int) -> [String: Any] {
        let clampedLimit = max(1, min(50, limit))
        let messagePayload = recentMessages.prefix(clampedLimit).map { message in
            [
                "id": message.id,
                "sender": message.sender,
                "preview": message.preview,
                "mediaPreviewURL": message.mediaPreviewURL as Any,
                "avatarURL": message.avatarURL as Any,
                "replyTarget": message.replyTarget as Any,
                "timestamp": Int(message.timestamp.timeIntervalSince1970)
            ]
        }

        return [
            "state": connectionState.rawValue,
            "statusText": statusText,
            "loggedIn": connectionState == .loggedIn,
            "qrCodeDataURL": qrCodeDataURL as Any,
            "lastError": lastError as Any,
            "messages": messagePayload
        ]
    }

    func sendMessage(to recipient: String, body: String) -> [String: Any] {
        start()

        let cleanRecipient = recipient
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBody = body
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanRecipient.isEmpty, !cleanBody.isEmpty else {
            return [
                "ok": false,
                "queued": false,
                "error": "invalid_arguments"
            ]
        }

        guard connectionState == .loggedIn else {
            return [
                "ok": false,
                "queued": false,
                "error": "not_logged_in"
            ]
        }

        let requestID = nextRequestID()
        sendProviderCommand([
            "command": "sendMessage",
            "requestId": requestID,
            "to": cleanRecipient,
            "body": cleanBody
        ])

        return [
            "ok": true,
            "queued": true,
            "requestId": requestID
        ]
    }

    private func nextRequestID() -> String {
        sentCommandSequence += 1
        return "wa-provider-\(sentCommandSequence)"
    }

    private func startProviderIfNeeded() {
        if providerProcess != nil {
            return
        }

        providerRestartWorkItem?.cancel()
        providerRestartWorkItem = nil

        guard fileManager.fileExists(atPath: providerScriptURL.path) else {
            performBridgeUpdate {
                connectionState = .error
                statusText = "WhatsApp provider unavailable"
                lastError = "Missing provider script at \(providerScriptURL.path)"
            }
            return
        }

        guard let nodeExecutableURL = resolveNodeExecutableURL() else {
            performBridgeUpdate {
                connectionState = .error
                statusText = "Node.js not found"
                lastError = "Unable to resolve a Node.js executable for the WhatsApp realtime provider"
            }
            return
        }

        do {
            try fileManager.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        } catch {
            performBridgeUpdate {
                connectionState = .error
                statusText = "WhatsApp provider unavailable"
                lastError = "Failed to prepare auth directory: \(error.localizedDescription)"
            }
            return
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let process = Process()
        process.executableURL = nodeExecutableURL
        process.arguments = [
            providerScriptURL.path,
            "--auth-dir",
            authDirectory.path
        ]
        process.currentDirectoryURL = Self.providerDirectory

        var environment = ProcessInfo.processInfo.environment
        environment["NODE_NO_WARNINGS"] = "1"
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            Task { @MainActor [weak self] in
                self?.consumeProviderOutput(data)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            Task { @MainActor [weak self] in
                self?.consumeProviderError(data)
            }
        }

        process.terminationHandler = { [weak self] terminatedProcess in
            Task { @MainActor [weak self] in
                self?.handleProviderTermination(terminatedProcess)
            }
        }

        do {
            try process.run()
            providerProcess = process
            providerInputHandle = stdinPipe.fileHandleForWriting
            providerOutputHandle = stdoutPipe.fileHandleForReading
            providerErrorHandle = stderrPipe.fileHandleForReading
            providerReady = false
            providerOutputBuffer.removeAll(keepingCapacity: true)
            providerErrorBuffer.removeAll(keepingCapacity: true)
            performBridgeUpdate {
                if connectionState == .idle || connectionState == .error {
                    connectionState = .loading
                    statusText = "Starting WhatsApp realtime bridge..."
                    if lastError == nil {
                        qrCodeDataURL = nil
                    }
                }
            }
            if shouldKeepProviderRunning {
                sendProviderCommand(
                    ["command": "start", "requestId": nextRequestID()],
                    dedupeKey: "start"
                )
            }
        } catch {
            providerProcess = nil
            providerInputHandle = nil
            providerOutputHandle = nil
            providerErrorHandle = nil
            performBridgeUpdate {
                connectionState = .error
                statusText = "Failed to start WhatsApp bridge"
                lastError = error.localizedDescription
            }
        }
    }

    private func resolveNodeExecutableURL() -> URL? {
        if let cachedNodeExecutableURL,
           fileManager.isExecutableFile(atPath: cachedNodeExecutableURL.path) {
            return cachedNodeExecutableURL
        }

        let envPathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
            .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("node", isDirectory: false) }

        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        let commonCandidates = [
            homeDirectory.appendingPathComponent(".nvm/versions/node/current/bin/node", isDirectory: false),
            URL(fileURLWithPath: "/opt/homebrew/bin/node", isDirectory: false),
            URL(fileURLWithPath: "/usr/local/bin/node", isDirectory: false),
            URL(fileURLWithPath: "/usr/bin/node", isDirectory: false)
        ]

        for candidate in envPathCandidates + commonCandidates {
            if fileManager.isExecutableFile(atPath: candidate.path) {
                cachedNodeExecutableURL = candidate
                return candidate
            }
        }

        let shellTask = Process()
        let stdoutPipe = Pipe()
        shellTask.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shellTask.arguments = [
            "-lc",
            "if [ -f \"$HOME/.zprofile\" ]; then source \"$HOME/.zprofile\" >/dev/null 2>&1; fi; if [ -f \"$HOME/.zshrc\" ]; then source \"$HOME/.zshrc\" >/dev/null 2>&1; fi; command -v node"
        ]
        shellTask.standardOutput = stdoutPipe
        shellTask.standardError = Pipe()

        do {
            try shellTask.run()
            shellTask.waitUntilExit()
        } catch {
            return nil
        }

        guard shellTask.terminationStatus == 0 else {
            return nil
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        guard let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty,
              fileManager.isExecutableFile(atPath: path) else {
            return nil
        }

        let resolvedURL = URL(fileURLWithPath: path, isDirectory: false)
        cachedNodeExecutableURL = resolvedURL
        return resolvedURL
    }

    private func sendProviderCommand(_ payload: [String: Any], dedupeKey: String? = nil) {
        if providerReady, let inputHandle = providerInputHandle {
            writeProviderCommand(payload, to: inputHandle)
            return
        }

        if let dedupeKey {
            guard !pendingCommandKeys.contains(dedupeKey) else { return }
            pendingCommandKeys.insert(dedupeKey)
        }
        pendingCommands.append(PendingWhatsAppProviderCommand(payload: payload, dedupeKey: dedupeKey))
        startProviderIfNeeded()
    }

    private func flushPendingCommands() {
        guard providerReady, let inputHandle = providerInputHandle else { return }
        let commands = pendingCommands
        pendingCommands.removeAll()
        pendingCommandKeys.removeAll()
        for pendingCommand in commands {
            writeProviderCommand(pendingCommand.payload, to: inputHandle)
        }
    }

    private func writeProviderCommand(_ payload: [String: Any], to inputHandle: FileHandle) {
        guard JSONSerialization.isValidJSONObject(payload) else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let newline = "\n".data(using: .utf8) else {
            return
        }
        inputHandle.write(data)
        inputHandle.write(newline)
    }

    private func consumeProviderOutput(_ data: Data) {
        providerOutputBuffer.append(data)
        consumeProviderBuffer(&providerOutputBuffer, isError: false)
    }

    private func consumeProviderError(_ data: Data) {
        providerErrorBuffer.append(data)
        consumeProviderBuffer(&providerErrorBuffer, isError: true)
    }

    private func consumeProviderBuffer(_ buffer: inout Data, isError: Bool) {
        let newline = Data([0x0A])
        while let range = buffer.range(of: newline) {
            let lineData = buffer.subdata(in: 0 ..< range.lowerBound)
            buffer.removeSubrange(0 ..< range.upperBound)
            guard let line = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty else {
                continue
            }
            if isError {
                ExtensionLogger.shared.log(Self.managedExtensionID, .warning, line)
            } else {
                handleProviderLine(line)
            }
        }
    }

    private func handleProviderLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let payload = object as? [String: Any] else {
            ExtensionLogger.shared.log(Self.managedExtensionID, .warning, "Unparseable provider event: \(line)")
            return
        }
        handleProviderEvent(payload)
    }

    private func handleProviderEvent(_ payload: [String: Any]) {
        guard let type = payload["type"] as? String else { return }

        switch type {
        case "ready":
            providerReady = true
            providerRestartAttempts = 0
            flushPendingCommands()
        case "state":
            applyProviderState(payload)
        case "message":
            handleProviderMessage(payload)
        case "sendResult":
            handleSendResult(payload)
        case "error":
            let message = normalizedString(payload["message"]) ?? "WhatsApp provider error"
            let details = normalizedString(payload["details"])
            ExtensionLogger.shared.log(Self.managedExtensionID, .error, details == nil ? message : "\(message): \(details!)")
            performBridgeUpdate {
                lastError = details == nil ? message : "\(message): \(details!)"
                if connectionState != .loggedIn {
                    connectionState = .error
                    statusText = "WhatsApp provider error"
                }
            }
        default:
            ExtensionLogger.shared.log(Self.managedExtensionID, .info, "WhatsApp provider event: \(type)")
        }
    }

    private func applyProviderState(_ payload: [String: Any]) {
        let rawState = normalizedString(payload["state"]) ?? ConnectionState.loading.rawValue
        let resolvedState = ConnectionState(rawValue: rawState) ?? .loading
        let status = normalizedString(payload["statusText"]) ?? defaultStatusText(for: resolvedState)
        let qrToken = normalizedString(payload["qr"])
        let qrImageDataURL = qrToken.flatMap(makeQRCodeDataURL(from:))

        performBridgeUpdate {
            connectionState = resolvedState
            statusText = status
            qrCodeDataURL = qrImageDataURL
            if resolvedState == .loggedIn {
                lastError = nil
            } else if resolvedState == .idle,
                      payload["loggedOut"] as? Bool == true {
                lastError = nil
            }
            if resolvedState == .idle,
               payload["loggedOut"] as? Bool == true {
                recentMessages.removeAll()
                seenMessageIDs.removeAll()
            }
        }
    }

    private func handleProviderMessage(_ payload: [String: Any]) {
        guard let identifier = normalizedString(payload["id"]) else {
            return
        }
        let sender = normalizedString(payload["sender"]) ?? "WhatsApp"
        let preview = normalizedString(payload["preview"]) ?? "New message"
        let mediaPreviewURL = normalizedString(payload["mediaPreviewURL"])
        let isReaction = payload["isReaction"] as? Bool ?? false
        let replyTarget = isReaction
            ? nil
            : (
                normalizedString(payload["chatJidAlt"])
                ?? normalizedString(payload["participantAlt"])
                ?? normalizedString(payload["chatJid"])
                ?? normalizedString(payload["participant"])
            )
        let avatarURL = resolvedAvatarURLString(
            from: normalizedString(payload["avatarURL"]),
            messageID: identifier
        )
        let timestampValue = payload["timestamp"]
        let timestamp = timestamp(from: timestampValue)

        if seenMessageIDs.contains(identifier) {
            applyMessageUpdate(
                id: identifier,
                sender: sender,
                preview: preview,
                mediaPreviewURL: mediaPreviewURL,
                avatarURL: avatarURL,
                replyTarget: replyTarget,
                timestamp: timestamp
            )
            return
        }

        seenMessageIDs.append(identifier)
        if seenMessageIDs.count > maxSeenMessageIDs {
            seenMessageIDs.removeFirst(seenMessageIDs.count - maxSeenMessageIDs)
        }

        ingestNewMessage(
            id: identifier,
            sender: sender,
            preview: preview,
            mediaPreviewURL: mediaPreviewURL,
            avatarURL: avatarURL,
            replyTarget: replyTarget,
            timestamp: timestamp
        )
    }

    private func applyMessageUpdate(
        id: String,
        sender: String,
        preview: String,
        mediaPreviewURL: String?,
        avatarURL: String?,
        replyTarget: String?,
        timestamp: Date
    ) {
        guard let existingIndex = recentMessages.firstIndex(where: { $0.id == id }) else {
            return
        }

        let existing = recentMessages[existingIndex]
        let resolvedMediaPreviewURL = mediaPreviewURL ?? existing.mediaPreviewURL
        let resolvedAvatarURL = avatarURL ?? existing.avatarURL
        let resolvedReplyTarget = replyTarget ?? existing.replyTarget
        guard existing.sender != sender ||
              existing.preview != preview ||
              existing.mediaPreviewURL != resolvedMediaPreviewURL ||
              existing.avatarURL != resolvedAvatarURL ||
              existing.replyTarget != resolvedReplyTarget else {
            return
        }

        performBridgeUpdate {
            recentMessages[existingIndex] = WhatsAppWebMessage(
                id: id,
                sender: sender,
                preview: preview,
                mediaPreviewURL: resolvedMediaPreviewURL,
                avatarURL: resolvedAvatarURL,
                replyTarget: resolvedReplyTarget,
                timestamp: timestamp
            )
        }

        if let resolvedAvatarURL, resolvedAvatarURL != existing.avatarURL {
            NotificationManager.shared.updateNotificationAvatar(
                sourceID: "whatsapp-web:\(id)",
                avatarURL: resolvedAvatarURL
            )
        }
    }

    private func handleSendResult(_ payload: [String: Any]) {
        guard let ok = payload["ok"] as? Bool else { return }
        let requestID = normalizedString(payload["requestId"]) ?? "unknown"
        if ok {
            let messageID = normalizedString(payload["messageId"]) ?? "unknown"
            ExtensionLogger.shared.log(Self.managedExtensionID, .info, "Sent WhatsApp message \(messageID) (request \(requestID))")
            return
        }

        let errorMessage = normalizedString(payload["error"]) ?? "Failed to send WhatsApp message"
        ExtensionLogger.shared.log(Self.managedExtensionID, .warning, "WhatsApp send failed (request \(requestID)): \(errorMessage)")
    }

    private func ingestNewMessage(
        id: String,
        sender: String,
        preview: String,
        mediaPreviewURL: String?,
        avatarURL: String?,
        replyTarget: String?,
        timestamp: Date
    ) {
        performBridgeUpdate {
            let message = WhatsAppWebMessage(
                id: id,
                sender: sender,
                preview: preview,
                mediaPreviewURL: mediaPreviewURL,
                avatarURL: avatarURL,
                replyTarget: replyTarget,
                timestamp: timestamp
            )

            recentMessages.removeAll { $0.id == id }
            recentMessages.removeAll { $0.preview == preview && $0.sender == sender }
            recentMessages.insert(message, at: 0)
            if recentMessages.count > 50 {
                recentMessages.removeLast(recentMessages.count - 50)
            }
            lastError = nil
            if connectionState != .loggedIn {
                connectionState = .loggedIn
                statusText = "Connected"
                qrCodeDataURL = nil
            }
        }

        let notification = IslandNotification(
            sourceID: "whatsapp-web:\(id)",
            appName: "WhatsApp",
            bundleIdentifier: "net.whatsapp.WhatsApp",
            appIcon: "message.fill",
            appIconURL: nil,
            title: sender,
            body: preview,
            senderName: sender,
            previewText: preview,
            avatarURL: avatarURL,
            timestamp: timestamp,
            tapAction: replyTarget.flatMap { target in
                var payload: [String: String] = [
                    "messageID": id,
                    "notificationSourceID": "whatsapp-web:\(id)",
                    "recipient": target,
                    "sender": sender,
                    "preview": preview
                ]
                if let mediaPreviewURL {
                    payload["mediaPreviewURL"] = mediaPreviewURL
                }
                if let avatarURL {
                    payload["avatarURL"] = avatarURL
                }
                return NotificationTapAction(
                    extensionID: Self.managedExtensionID,
                    actionID: "open-reply",
                    payload: payload,
                    presentation: .fullExpanded
                )
            }
        )
        NotificationManager.shared.addNotification(notification)
    }

    private func timestamp(from value: Any?) -> Date {
        if let number = value as? NSNumber {
            let milliseconds = number.doubleValue
            return Date(timeIntervalSince1970: milliseconds > 1_000_000_000_000 ? milliseconds / 1000 : milliseconds)
        }
        if let string = normalizedString(value),
           let milliseconds = Double(string) {
            return Date(timeIntervalSince1970: milliseconds > 1_000_000_000_000 ? milliseconds / 1000 : milliseconds)
        }
        return Date()
    }

    private func defaultStatusText(for state: ConnectionState) -> String {
        switch state {
        case .idle:
            return "Not connected"
        case .loading:
            return "Connecting to WhatsApp..."
        case .qrReady:
            return "Scan QR code with WhatsApp"
        case .loggedIn:
            return "Connected"
        case .error:
            return "WhatsApp provider error"
        }
    }

    private func normalizedString(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed
    }

    private func handleProviderTermination(_ terminatedProcess: Process) {
        providerOutputHandle?.readabilityHandler = nil
        providerErrorHandle?.readabilityHandler = nil
        providerInputHandle = nil
        providerOutputHandle = nil
        providerErrorHandle = nil
        providerProcess = nil
        providerReady = false
        providerOutputBuffer.removeAll(keepingCapacity: false)
        providerErrorBuffer.removeAll(keepingCapacity: false)

        let shouldRestart = shouldKeepProviderRunning
        let exitCode = terminatedProcess.terminationStatus
        let terminationReason = terminatedProcess.terminationReason == .exit ? "exit" : "uncaught signal"
        ExtensionLogger.shared.log(
            Self.managedExtensionID,
            exitCode == 0 ? .info : .warning,
            "WhatsApp provider terminated (\(terminationReason), code \(exitCode))"
        )

        if shouldRestart {
            scheduleProviderRestart()
        }
    }

    private func scheduleProviderRestart() {
        providerRestartWorkItem?.cancel()
        let delay = min(30.0, pow(1.8, Double(providerRestartAttempts)) * 2.0)
        providerRestartAttempts += 1

        performBridgeUpdate {
            if connectionState != .loggedIn {
                connectionState = .loading
                statusText = delay < 1 ? "Restarting WhatsApp provider..." : "Restarting WhatsApp provider in \(Int(ceil(delay)))s..."
            }
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.providerRestartWorkItem = nil
            self.startProviderIfNeeded()
        }
        providerRestartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func makeQRCodeDataURL(from token: String) -> String? {
        guard let data = token.data(using: .utf8) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("Q", forKey: "inputCorrectionLevel")
        guard let outputImage = filter.outputImage else { return nil }

        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = qrRenderContext.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }

        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            return nil
        }

        return "data:image/png;base64,\(pngData.base64EncodedString())"
    }

    private func resolvedAvatarURLString(from rawURLString: String?, messageID: String) -> String? {
        guard let rawURLString = normalizedString(rawURLString) else { return nil }

        if rawURLString.hasPrefix("/") {
            return URL(fileURLWithPath: rawURLString).absoluteString
        }

        guard let url = URL(string: rawURLString) else {
            return nil
        }

        if url.isFileURL {
            return url.absoluteString
        }

        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }

        if let cached = cachedLocalAvatarURL(forRemoteURLString: rawURLString) {
            return cached
        }

        downloadAvatarIfNeeded(remoteURLString: rawURLString, messageID: messageID)
        return nil
    }

    private func cachedLocalAvatarURL(forRemoteURLString remoteURLString: String) -> String? {
        if let cached = cachedAvatarFileURLs[remoteURLString],
           let cachedURL = URL(string: cached),
           fileManager.fileExists(atPath: cachedURL.path) {
            return cached
        }

        let fileURL = avatarCacheFileURL(forRemoteURLString: remoteURLString)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let localURLString = fileURL.absoluteString
        cachedAvatarFileURLs[remoteURLString] = localURLString
        return localURLString
    }

    private func avatarCacheFileURL(forRemoteURLString remoteURLString: String) -> URL {
        let digest = SHA256.hash(data: Data(remoteURLString.utf8))
        let fileName = digest.map { String(format: "%02x", $0) }.joined()
        return avatarCacheDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    private func downloadAvatarIfNeeded(remoteURLString: String, messageID: String) {
        guard !pendingAvatarDownloads.contains(remoteURLString),
              let remoteURL = URL(string: remoteURLString) else {
            return
        }

        pendingAvatarDownloads.insert(remoteURLString)

        let managedExtensionID = Self.managedExtensionID
        let cacheDirectory = avatarCacheDirectory
        let destinationURL = avatarCacheFileURL(forRemoteURLString: remoteURLString)
        URLSession.shared.dataTask(with: remoteURL) { data, _, error in
            defer {
                Task { @MainActor [weak self] in
                    self?.pendingAvatarDownloads.remove(remoteURLString)
                }
            }

            guard error == nil,
                  let data,
                  !data.isEmpty,
                  NSImage(data: data) != nil else {
                return
            }

            do {
                try FileManager.default.createDirectory(
                    at: cacheDirectory,
                    withIntermediateDirectories: true
                )
                try data.write(to: destinationURL, options: .atomic)
            } catch {
                ExtensionLogger.shared.log(
                    managedExtensionID,
                    .warning,
                    "Failed to cache WhatsApp avatar: \(error.localizedDescription)"
                )
                return
            }

            let localURLString = destinationURL.absoluteString
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.cachedAvatarFileURLs[remoteURLString] = localURLString
                guard let existingMessage = self.recentMessages.first(where: { $0.id == messageID }) else {
                    return
                }
                self.applyMessageUpdate(
                    id: messageID,
                    sender: existingMessage.sender,
                    preview: existingMessage.preview,
                    mediaPreviewURL: existingMessage.mediaPreviewURL,
                    avatarURL: localURLString,
                    replyTarget: existingMessage.replyTarget,
                    timestamp: existingMessage.timestamp
                )
            }
        }.resume()
    }
}
