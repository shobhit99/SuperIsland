import Foundation
import JavaScriptCore
import AppKit
import UserNotifications

final class ExtensionJSRuntime {
    enum RuntimeError: LocalizedError {
        case contextInitializationFailed
        case scriptReadFailed(URL)
        case scriptEvaluationFailed(String)

        var errorDescription: String? {
            switch self {
            case .contextInitializationFailed:
                return "Failed to initialize JSContext"
            case .scriptReadFailed(let url):
                return "Failed to read extension script at \(url.path)"
            case .scriptEvaluationFailed(let message):
                return "Failed to evaluate extension script: \(message)"
            }
        }
    }

    let context: JSContext
    let extensionID: String
    let manifest: ExtensionManifest

    private weak var manager: ExtensionManager?
    private var moduleConfig: JSValue?
    private var islandNamespace: JSValue?
    private var timers: [Int: Timer] = [:]
    private var nextTimerID: Int = 1
    private var didActivate = false

    private let defaults = UserDefaults.standard
    private var islandActivationModule: ActiveModule {
        manifest.capabilities.notificationFeed ? .builtIn(.notifications) : .extension_(extensionID)
    }

    init(manifest: ExtensionManifest, manager: ExtensionManager) throws {
        guard let context = JSContext() else {
            throw RuntimeError.contextInitializationFailed
        }

        self.context = context
        self.manifest = manifest
        self.extensionID = manifest.id
        self.manager = manager

        ExtensionSandbox.configureContext(context, extensionID: manifest.id, permissions: manifest.permissions)

        // Catch-all JS exception handler — without this, uncaught exceptions
        // in extension code would leave `context.exception` dangling and
        // potentially spam stderr. The handler logs structured details and
        // lets the runtime recover instead of taking down the island.
        let extID = manifest.id
        context.exceptionHandler = { ctx, exception in
            let message = exception?.toString() ?? "<no message>"
            let stack = exception?.forProperty("stack")?.toString() ?? ""
            let detail = stack.isEmpty ? message : "\(message)\n\(stack)"
            ExtensionLogger.shared.log(extID, .error, "JS exception: \(detail)")
            ctx?.exception = nil
        }

        injectAPI()

        guard let script = try? String(contentsOf: manifest.entryURL, encoding: .utf8) else {
            throw RuntimeError.scriptReadFailed(manifest.entryURL)
        }

        context.evaluateScript(script, withSourceURL: manifest.entryURL)

        if let exception = context.exception?.toString() {
            context.exception = nil
            throw RuntimeError.scriptEvaluationFailed(exception)
        }
    }

    /// Invoke a JS callback with full crash isolation.
    /// Any exception is logged, the context's exception state is cleared,
    /// and the function returns `nil` instead of propagating the failure —
    /// so one bad extension can never take down the island UI.
    @discardableResult
    private func invokeJS(_ label: String, _ body: () -> JSValue?) -> JSValue? {
        let result = body()
        if let exception = context.exception {
            let message = exception.toString() ?? "<unknown>"
            ExtensionLogger.shared.log(extensionID, .error, "\(label) threw: \(message)")
            context.exception = nil
            return nil
        }
        return result
    }

    deinit {
        invalidateAllTimers()
    }

    func activate() {
        guard !didActivate else { return }
        didActivate = true
        callLifecycleHook(named: "onActivate")
    }

    func deactivate() {
        callLifecycleHook(named: "onDeactivate")
        invalidateAllTimers()
        didActivate = false
    }

    func cleanup() {
        deactivate()
    }

    @MainActor
    func fetchState() -> ExtensionViewState? {
        syncIslandState()

        guard let config = moduleConfig else {
            return nil
        }

        let compact = renderNode(from: config, key: "compact") ?? .empty
        let expanded = renderNode(from: config, key: "expanded") ?? compact
        let fullExpanded = renderNode(from: config, key: "fullExpanded")

        var minimalLeading: ViewNode?
        var minimalTrailing: ViewNode?
        var minimalCompactPrecedenceValue = 1
        if let minimalCompact = config.forProperty("minimalCompact"), !minimalCompact.isUndefined, !minimalCompact.isNull {
            minimalLeading = renderNode(from: minimalCompact, key: "leading")
            minimalTrailing = renderNode(from: minimalCompact, key: "trailing")
            minimalCompactPrecedenceValue = resolveMinimalCompactPrecedence(from: minimalCompact)
        }

        return ExtensionViewState(
            compact: compact,
            expanded: expanded,
            fullExpanded: fullExpanded,
            minimalLeading: minimalLeading,
            minimalTrailing: minimalTrailing,
            minimalCompactPrecedence: minimalCompactPrecedenceValue
        )
    }

    /// Fire the extension's `onSettingsChanged(key, value)` JS hook. The host
    /// calls this whenever a settings toggle/slider/text flips in
    /// UserDefaults so the extension can react (e.g. install/uninstall CLI
    /// hooks, re-fetch state, etc.). Swallows any JS exception.
    @MainActor
    func notifySettingsChanged(key: String, value: Any?) {
        guard let callback = moduleConfig?.forProperty("onSettingsChanged"),
              !callback.isUndefined,
              !callback.isNull else {
            return
        }
        invokeJS("onSettingsChanged(\(key))") {
            if let value {
                return callback.call(withArguments: [key, value])
            }
            return callback.call(withArguments: [key, NSNull()])
        }
    }

    @MainActor
    func handleAction(actionID: String, value: Any?) {
        syncIslandState()

        guard let callback = moduleConfig?.forProperty("onAction"), !callback.isUndefined else {
            return
        }

        invokeJS("onAction(\(actionID))") {
            if let value {
                return callback.call(withArguments: [actionID, value])
            }
            return callback.call(withArguments: [actionID])
        }
    }

    private func injectAPI() {
        let superIsland = JSValue(newObjectIn: context)!
        context.setObject(superIsland, forKeyedSubscript: "SuperIsland" as NSString)

        injectModuleRegistration(into: superIsland)
        injectStore(into: superIsland)
        injectSettings(into: superIsland)
        injectIslandControls(into: superIsland)
        injectNotifications(into: superIsland)
        injectHTTP(into: superIsland)
        injectSystem(into: superIsland)
        injectFeedback(into: superIsland)
        injectMascot(into: superIsland)
        injectConsole(into: superIsland)
        injectTimers()
        injectViewHelpers()
        injectComponents()
    }

    private func injectModuleRegistration(into superIsland: JSValue) {
        let registerModule: @convention(block) (JSValue) -> Void = { [weak self] config in
            guard let self else { return }
            self.moduleConfig = config
            ExtensionLogger.shared.log(self.extensionID, .info, "Module registered")
        }
        superIsland.setObject(registerModule, forKeyedSubscript: "registerModule" as NSString)
    }

    private func resolveMinimalCompactPrecedence(from config: JSValue) -> Int {
        guard let rawValue = config.forProperty("precedence"), !rawValue.isUndefined, !rawValue.isNull else {
            return 1
        }

        if rawValue.isNumber {
            return max(0, Int(rawValue.toInt32()))
        }

        if rawValue.isObject,
           let result = invokeJS("precedence()", { rawValue.call(withArguments: []) }),
           !result.isUndefined,
           !result.isNull {
            return max(0, Int(result.toInt32()))
        }

        return 1
    }

    private func injectStore(into superIsland: JSValue) {
        let store = JSValue(newObjectIn: context)!

        let getValue: @convention(block) (String) -> JSValue? = { [weak self] key in
            guard let self else { return nil }
            let namespacedKey = self.storeKey(for: key)
            guard let value = self.defaults.object(forKey: namespacedKey) else {
                return JSValue(nullIn: self.context)
            }
            return self.jsValueFromStoredObject(value)
        }

        let setValue: @convention(block) (String, JSValue) -> Void = { [weak self] key, value in
            guard let self else { return }
            let namespacedKey = self.storeKey(for: key)
            self.save(value: value.toObject(), forKey: namespacedKey)
        }

        store.setObject(getValue, forKeyedSubscript: "get" as NSString)
        store.setObject(setValue, forKeyedSubscript: "set" as NSString)
        superIsland.setObject(store, forKeyedSubscript: "store" as NSString)
    }

    private func injectSettings(into superIsland: JSValue) {
        let settings = JSValue(newObjectIn: context)!

        let getValue: @convention(block) (String) -> JSValue? = { [weak self] key in
            guard let self else { return nil }
            let namespacedKey = self.settingsKey(for: key)
            guard let value = self.defaults.object(forKey: namespacedKey) else {
                return JSValue(nullIn: self.context)
            }
            return self.jsValueFromStoredObject(value)
        }

        let setValue: @convention(block) (String, JSValue) -> Void = { [weak self] key, value in
            guard let self else { return }
            let namespacedKey = self.settingsKey(for: key)
            self.save(value: value.toObject(), forKey: namespacedKey)
        }

        settings.setObject(getValue, forKeyedSubscript: "get" as NSString)
        settings.setObject(setValue, forKeyedSubscript: "set" as NSString)
        superIsland.setObject(settings, forKeyedSubscript: "settings" as NSString)
    }

    private func injectIslandControls(into superIsland: JSValue) {
        let island = JSValue(newObjectIn: context)!

        let activate: @convention(block) (JSValue?) -> Void = { [weak self] autoDismissArg in
            guard let self else { return }
            let autoDismiss = autoDismissArg?.isBoolean == true ? autoDismissArg?.toBool() ?? true : true
            DispatchQueue.main.async {
                AppState.shared.showHUD(module: self.islandActivationModule, autoDismiss: autoDismiss)
            }
        }

        let dismiss: @convention(block) () -> Void = {
            DispatchQueue.main.async {
                AppState.shared.dismiss()
            }
        }

        island.setObject(activate, forKeyedSubscript: "activate" as NSString)
        island.setObject(dismiss, forKeyedSubscript: "dismiss" as NSString)
        island.setObject("compact", forKeyedSubscript: "state" as NSString)
        island.setObject(false, forKeyedSubscript: "isActive" as NSString)

        islandNamespace = island
        superIsland.setObject(island, forKeyedSubscript: "island" as NSString)
    }

    private func injectNotifications(into superIsland: JSValue) {
        let notifications = JSValue(newObjectIn: context)!

        let send: @convention(block) (JSValue) -> Void = { [weak self] options in
            guard let self else { return }
            let title = self.normalizedText(options.forProperty("title")?.toString()) ?? ""
            let body = self.normalizedText(options.forProperty("body")?.toString()) ?? ""
            let sound = options.forProperty("sound")?.toBool() ?? false
            let appName = self.normalizedText(options.forProperty("appName")?.toString())
            let bundleIdentifier = self.normalizedText(options.forProperty("bundleIdentifier")?.toString())
            let senderName = self.normalizedText(options.forProperty("senderName")?.toString())
            let previewText = self.normalizedText(options.forProperty("previewText")?.toString())
            let avatarURL = self.normalizedResourceURLString(options.forProperty("avatarURL")?.toString())
            let appIconURL = self.normalizedResourceURLString(options.forProperty("appIconURL")?.toString())
            let sourceID = self.normalizedText(options.forProperty("id")?.toString())
            let tapAction = self.notificationTapAction(from: options.forProperty("tapAction"))
            let shouldShowSystemNotification = options.forProperty("systemNotification")?.isBoolean == true
                ? (options.forProperty("systemNotification")?.toBool() ?? true)
                : true
            self.sendNotification(
                title: title,
                body: body,
                sound: sound,
                appName: appName,
                bundleIdentifier: bundleIdentifier,
                senderName: senderName,
                previewText: previewText,
                avatarURL: avatarURL,
                appIconURL: appIconURL,
                sourceID: sourceID,
                tapAction: tapAction,
                shouldShowSystemNotification: shouldShowSystemNotification
            )
        }

        notifications.setObject(send, forKeyedSubscript: "send" as NSString)
        superIsland.setObject(notifications, forKeyedSubscript: "notifications" as NSString)
    }

    private func injectHTTP(into superIsland: JSValue) {
        let fetchSync: @convention(block) (String, JSValue?) -> JSValue? = { [weak self] urlString, options in
            guard let self else { return nil }
            return self.fetchSync(urlString: urlString, options: options)
        }

        // Truly-async fetch: takes a JS callback and resolves on a background
        // queue, so the main thread never blocks. The sync variant is kept
        // for extensions that still rely on it, but agents-status and any new
        // caller should go through SuperIsland.http.fetch (promise-based).
        let fetchAsync: @convention(block) (String, JSValue?, JSValue) -> Void = { [weak self] urlString, options, callback in
            guard let self else { return }
            // Capture the payload on the JS thread, then hop off main for the
            // URLSession wait. When it completes, dispatch back to main and
            // invoke the JS callback with the result.
            let method = jsOptionalString(options, key: "method")
            let body = jsOptionalString(options, key: "body")
            let headers = options?.forProperty("headers")?.toDictionary() as? [String: String]
            let hasPermission = self.manifest.permissions.contains("network")
            let ctx = self.context

            DispatchQueue.global(qos: .userInitiated).async {
                let result = AsyncFetchResult.perform(
                    urlString: urlString,
                    method: method,
                    body: body,
                    headers: headers,
                    hasPermission: hasPermission
                )
                DispatchQueue.main.async {
                    let js = JSValue(object: result.asDictionary(), in: ctx) ?? JSValue(nullIn: ctx)
                    callback.call(withArguments: [js as Any])
                }
            }
        }

        superIsland.setObject(fetchSync, forKeyedSubscript: "__fetchSync" as NSString)
        superIsland.setObject(fetchAsync, forKeyedSubscript: "__fetchAsync" as NSString)

        if manifest.permissions.contains("network") {
            context.evaluateScript(
                """
                SuperIsland.http = {
                  fetch: function(url, options) {
                    return new Promise(function(resolve) {
                      try {
                        SuperIsland.__fetchAsync(url, options || {}, function(res) {
                          resolve(res);
                        });
                      } catch (e) {
                        resolve({ status: 0, data: null, text: "", error: String(e) });
                      }
                    });
                  }
                };
                """
            )
        } else {
            context.evaluateScript(
                "SuperIsland.http = { fetch: function() { throw new Error('Permission denied: network'); } };"
            )
        }
    }

    private func injectSystem(into superIsland: JSValue) {
        let system = JSValue(newObjectIn: context)!

        let getAIUsage: @convention(block) () -> JSValue? = { [weak self] in
            guard let self else { return nil }
            guard self.manifest.permissions.contains("usage") else {
                return JSValue(nullIn: self.context)
            }
            return JSValue(object: AIUsageProvider.snapshot(), in: self.context)
        }

        let getNowPlaying: @convention(block) () -> JSValue? = { [weak self] in
            guard let self else { return nil }
            guard self.manifest.permissions.contains("media") else {
                return JSValue(nullIn: self.context)
            }
            guard Thread.isMainThread else {
                return JSValue(nullIn: self.context)
            }

            let payload = MainActor.assumeIsolated {
                NowPlayingManager.shared.normalizedSnapshot()
            }
            return JSValue(object: payload ?? NSNull(), in: self.context)
        }

        let getLatestNotification: @convention(block) () -> JSValue? = { [weak self] in
            guard let self else { return nil }
            guard self.manifest.permissions.contains("notifications") else {
                return JSValue(nullIn: self.context)
            }
            guard Thread.isMainThread else {
                return JSValue(nullIn: self.context)
            }

            let payload = MainActor.assumeIsolated {
                self.latestNotificationPayload()
            }
            return JSValue(object: payload ?? NSNull(), in: self.context)
        }

        let getRecentNotifications: @convention(block) (JSValue?) -> JSValue? = { [weak self] limitArg in
            guard let self else { return nil }
            guard self.manifest.permissions.contains("notifications") else {
                return JSValue(object: [], in: self.context)
            }
            guard Thread.isMainThread else {
                return JSValue(object: [], in: self.context)
            }

            var limit = 20
            if let limitArg, !limitArg.isUndefined, !limitArg.isNull {
                let candidate = Int(limitArg.toInt32())
                if candidate > 0 {
                    limit = candidate
                }
            }
            limit = max(1, min(100, limit))

            let payload = MainActor.assumeIsolated {
                self.recentNotificationPayloads(limit: limit)
            }
            return JSValue(object: payload, in: self.context)
        }

        let getWhatsAppWeb: @convention(block) (JSValue?) -> JSValue? = { [weak self] limitArg in
            guard let self else { return JSValue(nullIn: JSContext.current()) }
            guard self.manifest.permissions.contains("network") else {
                return JSValue(object: NSNull(), in: self.context)
            }
            guard Thread.isMainThread else {
                return JSValue(object: NSNull(), in: self.context)
            }

            var limit = 10
            if let limitArg, !limitArg.isUndefined, !limitArg.isNull {
                let candidate = Int(limitArg.toInt32())
                if candidate > 0 {
                    limit = candidate
                }
            }
            limit = max(1, min(50, limit))

            let payload = MainActor.assumeIsolated {
                WhatsAppWebBridge.shared.snapshot(limit: limit)
            }
            return JSValue(object: payload, in: self.context)
        }

        let startWhatsAppWeb: @convention(block) () -> Void = { [weak self] in
            guard let self else { return }
            guard self.manifest.permissions.contains("network") else { return }
            Task { @MainActor in
                WhatsAppWebBridge.shared.start()
            }
        }

        let refreshWhatsAppWebQR: @convention(block) () -> Void = { [weak self] in
            guard let self else { return }
            guard self.manifest.permissions.contains("network") else { return }
            Task { @MainActor in
                WhatsAppWebBridge.shared.refreshQRCode()
            }
        }

        let sendWhatsAppWebMessage: @convention(block) (String, String) -> JSValue? = { [weak self] recipient, message in
            guard let self else { return JSValue(nullIn: JSContext.current()) }
            guard self.manifest.permissions.contains("network") else {
                return JSValue(object: ["ok": false, "queued": false, "error": "permission_denied"], in: self.context)
            }
            guard Thread.isMainThread else {
                return JSValue(object: ["ok": false, "queued": false, "error": "main_thread_required"], in: self.context)
            }

            let payload = MainActor.assumeIsolated {
                WhatsAppWebBridge.shared.sendMessage(to: recipient, body: message)
            }
            return JSValue(object: payload, in: self.context)
        }

        let sendWhatsAppWebMessageAsync: @convention(block) (String, String) -> Bool = { [weak self] recipient, message in
            guard let self else { return false }
            guard self.manifest.permissions.contains("network") else { return false }

            Task { @MainActor in
                _ = WhatsAppWebBridge.shared.sendMessage(to: recipient, body: message)
            }
            return true
        }

        let dismissNotification: @convention(block) (String) -> Bool = { sourceID in
            let normalizedSourceID = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedSourceID.isEmpty else { return false }
            return MainActor.assumeIsolated {
                NotificationManager.shared.clearNotification(normalizedSourceID)
                return true
            }
        }

        let closePresentedInteraction: @convention(block) () -> Bool = { [weak self] in
            guard let self, let manager = self.manager else { return false }
            return MainActor.assumeIsolated {
                manager.closePresentedInteraction(extensionID: self.extensionID)
            }
        }

        system.setObject(getAIUsage, forKeyedSubscript: "getAIUsage" as NSString)
        system.setObject(getNowPlaying, forKeyedSubscript: "getNowPlaying" as NSString)
        system.setObject(getLatestNotification, forKeyedSubscript: "getLatestNotification" as NSString)
        system.setObject(getRecentNotifications, forKeyedSubscript: "getRecentNotifications" as NSString)
        system.setObject(getWhatsAppWeb, forKeyedSubscript: "getWhatsAppWeb" as NSString)
        system.setObject(startWhatsAppWeb, forKeyedSubscript: "startWhatsAppWeb" as NSString)
        system.setObject(refreshWhatsAppWebQR, forKeyedSubscript: "refreshWhatsAppWebQR" as NSString)
        system.setObject(sendWhatsAppWebMessage, forKeyedSubscript: "sendWhatsAppWebMessage" as NSString)
        system.setObject(sendWhatsAppWebMessageAsync, forKeyedSubscript: "sendWhatsAppWebMessageAsync" as NSString)
        system.setObject(dismissNotification, forKeyedSubscript: "dismissNotification" as NSString)
        system.setObject(closePresentedInteraction, forKeyedSubscript: "closePresentedInteraction" as NSString)
        superIsland.setObject(system, forKeyedSubscript: "system" as NSString)
    }

    private func injectFeedback(into superIsland: JSValue) {
        let playFeedback: @convention(block) (String) -> Void = { type in
            DispatchQueue.main.async {
                HapticFeedbackController.play(named: type)
            }
        }

        let openURL: @convention(block) (String) -> Void = { urlString in
            guard let url = URL(string: urlString) else { return }
            NSWorkspace.shared.open(url)
        }

        superIsland.setObject(playFeedback, forKeyedSubscript: "playFeedback" as NSString)
        superIsland.setObject(openURL, forKeyedSubscript: "openURL" as NSString)
    }

    private func injectMascot(into superIsland: JSValue) {
        let mascot = JSValue(newObjectIn: context)!

        let setExpression: @convention(block) (String) -> Void = { expression in
            let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            DispatchQueue.main.async {
                MascotManager.shared.setExpression(trimmed)
            }
        }

        let getExpression: @convention(block) () -> String = {
            return MainActor.assumeIsolated {
                MascotManager.shared.currentExpression
            }
        }

        let getSelected: @convention(block) () -> JSValue? = { [weak self] in
            guard let self else { return nil }
            let info = MainActor.assumeIsolated {
                let mgr = MascotManager.shared
                return ["slug": mgr.selectedSlug, "name": mgr.currentTemplateName] as [String: Any]
            }
            return JSValue(object: info, in: self.context)
        }

        let list: @convention(block) () -> JSValue? = { [weak self] in
            guard let self else { return nil }
            let mascots = MainActor.assumeIsolated {
                MascotManager.shared.availableMascots.map { entry in
                    ["slug": entry.slug, "name": entry.name] as [String: Any]
                }
            }
            return JSValue(object: mascots, in: self.context)
        }

        let setInput: @convention(block) (String, JSValue) -> Void = { name, value in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let converted: Any = value.toBool()
            DispatchQueue.main.async {
                MascotManager.shared.setInput(trimmed, converted)
            }
        }

        mascot.setObject(setExpression, forKeyedSubscript: "setExpression" as NSString)
        mascot.setObject(getExpression, forKeyedSubscript: "getExpression" as NSString)
        mascot.setObject(getSelected, forKeyedSubscript: "getSelected" as NSString)
        mascot.setObject(list, forKeyedSubscript: "list" as NSString)
        mascot.setObject(setInput, forKeyedSubscript: "setInput" as NSString)
        superIsland.setObject(mascot, forKeyedSubscript: "mascot" as NSString)
    }

    private func injectConsole(into superIsland: JSValue) {
        let logInfo: @convention(block) (String) -> Void = { [weak self] message in
            guard let self else { return }
            ExtensionLogger.shared.log(self.extensionID, .info, message)
        }

        let logWarn: @convention(block) (String) -> Void = { [weak self] message in
            guard let self else { return }
            ExtensionLogger.shared.log(self.extensionID, .warning, message)
        }

        let logError: @convention(block) (String) -> Void = { [weak self] message in
            guard let self else { return }
            ExtensionLogger.shared.log(self.extensionID, .error, message)
        }

        superIsland.setObject(logInfo, forKeyedSubscript: "__log" as NSString)
        superIsland.setObject(logWarn, forKeyedSubscript: "__warn" as NSString)
        superIsland.setObject(logError, forKeyedSubscript: "__error" as NSString)

        context.evaluateScript(
            """
            globalThis.console = {
              log: function() { SuperIsland.__log(Array.from(arguments).map(String).join(' ')); },
              warn: function() { SuperIsland.__warn(Array.from(arguments).map(String).join(' ')); },
              error: function() { SuperIsland.__error(Array.from(arguments).map(String).join(' ')); }
            };
            """
        )
    }

    private func injectTimers() {
        let setIntervalBlock: @convention(block) (JSValue, Double) -> Int = { [weak self] callback, intervalMS in
            guard let self else { return -1 }
            return self.scheduleTimer(callback: callback, milliseconds: intervalMS, repeats: true)
        }

        let setTimeoutBlock: @convention(block) (JSValue, Double) -> Int = { [weak self] callback, timeoutMS in
            guard let self else { return -1 }
            return self.scheduleTimer(callback: callback, milliseconds: timeoutMS, repeats: false)
        }

        let clearTimerBlock: @convention(block) (Int) -> Void = { [weak self] timerID in
            self?.clearTimer(id: timerID)
        }

        context.setObject(setIntervalBlock, forKeyedSubscript: "setInterval" as NSString)
        context.setObject(setTimeoutBlock, forKeyedSubscript: "setTimeout" as NSString)
        context.setObject(clearTimerBlock, forKeyedSubscript: "clearInterval" as NSString)
        context.setObject(clearTimerBlock, forKeyedSubscript: "clearTimeout" as NSString)
    }

    private func injectViewHelpers() {
        context.evaluateScript(
            """
            globalThis.View = {
              hstack: function(children, opts) { return { type: 'hstack', spacing: (opts && opts.spacing) ?? 8, align: opts && opts.align, distribution: opts && opts.distribution, children: children || [] }; },
              vstack: function(children, opts) { return { type: 'vstack', spacing: (opts && opts.spacing) ?? 4, align: opts && opts.align, distribution: opts && opts.distribution, children: children || [] }; },
              zstack: function(children) { return { type: 'zstack', children: children || [] }; },
              spacer: function(minLength) { return { type: 'spacer', minLength: minLength }; },
              scroll: function(child, opts) { return { type: 'scroll', child: child, axes: (opts && opts.axes) ?? 'vertical', showsIndicators: opts && opts.showsIndicators !== undefined ? !!opts.showsIndicators : true }; },
              text: function(value, opts) { return { type: 'text', value: String(value ?? ''), style: (opts && opts.style) ?? 'body', color: opts && opts.color, lineLimit: opts && opts.lineLimit }; },
              markdownText: function(value, opts) { return { type: 'markdown-text', value: String(value ?? ''), style: (opts && opts.style) ?? 'body', color: opts && opts.color, lineLimit: opts && opts.lineLimit }; },
              icon: function(name, opts) { return { type: 'icon', name: name, size: (opts && opts.size) ?? 14, color: opts && opts.color }; },
              image: function(url, opts) { return { type: 'image', url: url, width: opts.width, height: opts.height, cornerRadius: opts.cornerRadius }; },
              progress: function(value, opts) { return { type: 'progress', value: value, total: (opts && opts.total) ?? 1, color: opts && opts.color }; },
              circularProgress: function(value, opts) { return { type: 'circular-progress', value: value, total: (opts && opts.total) ?? 1, lineWidth: (opts && opts.lineWidth) ?? 3, color: opts && opts.color }; },
              gauge: function(value, opts) { return { type: 'gauge', value: value, min: (opts && opts.min) ?? 0, max: (opts && opts.max) ?? 1, label: opts && opts.label }; },
              divider: function() { return { type: 'divider' }; },
              button: function(label, action) { return { type: 'button', label: label, action: action }; },
              inputBox: function(placeholder, text, action, opts) { return { type: 'input-box', id: (opts && opts.id) ? String(opts.id) : '', placeholder: String(placeholder ?? ''), text: String(text ?? ''), action: action, autoFocus: opts && opts.autoFocus !== undefined ? !!opts.autoFocus : true, minHeight: (opts && opts.minHeight) ? Number(opts.minHeight) : 72, showsEmojiButton: opts && opts.showsEmojiButton !== undefined ? !!opts.showsEmojiButton : false }; },
              toggle: function(isOn, label, action) { return { type: 'toggle', isOn: !!isOn, label: label, action: action }; },
              slider: function(value, min, max, action) { return { type: 'slider', value: value, min: min, max: max, action: action }; },
              padding: function(child, opts) { return { type: 'padding', child: child, edges: (opts && opts.edges) ?? 'all', amount: (opts && opts.amount) ?? 8 }; },
              frame: function(child, opts) { return { type: 'frame', child: child, width: opts && opts.width, height: opts && opts.height, maxWidth: opts && opts.maxWidth, maxHeight: opts && opts.maxHeight, alignment: opts && opts.alignment }; },
              opacity: function(child, value) { return { type: 'opacity', child: child, value: value }; },
              background: function(child, color) { return { type: 'background', child: child, color: color }; },
              cornerRadius: function(child, radius) { return { type: 'cornerRadius', child: child, radius: radius }; },
              animate: function(child, kind) { return { type: 'animation', child: child, kind: kind }; },
              mascot: function(opts) { return { type: 'mascot', size: (opts && opts.size) ?? 60, expression: opts && opts.expression }; },
              when: function(condition, thenNode, elseNode) { return condition ? thenNode : (elseNode ?? null); },
              timerText: function(seconds, opts) {
                var safe = Math.max(0, Math.floor(seconds));
                var m = Math.floor(safe / 60);
                var s = safe % 60;
                return {
                  type: 'text',
                  value: String(m).padStart(2, '0') + ':' + String(s).padStart(2, '0'),
                  style: (opts && opts.style) ?? 'monospaced'
                };
              }
            };
            """
        )
    }

    private func injectComponents() {
        context.evaluateScript(
            """
            (function() {
              function shortcutBadge(label) {
                return View.cornerRadius(
                  View.background(
                    View.padding(
                      View.text(String(label ?? ''), {
                        style: 'footnote',
                        color: { r: 1, g: 1, b: 1, a: 0.8 },
                        lineLimit: 1
                      }),
                      { edges: 'all', amount: 3 }
                    ),
                    { r: 1, g: 1, b: 1, a: 0.085 }
                  ),
                  5
                );
              }

              function shortcutHint() {
                return View.hstack([
                  shortcutBadge('Enter'),
                  View.text('Send', {
                    style: 'footnote',
                    color: { r: 1, g: 1, b: 1, a: 0.52 },
                    lineLimit: 1
                  }),
                  View.text('|', {
                    style: 'footnote',
                    color: { r: 1, g: 1, b: 1, a: 0.32 },
                    lineLimit: 1
                  }),
                  shortcutBadge('Shift + Enter'),
                  View.text('New line', {
                    style: 'footnote',
                    color: { r: 1, g: 1, b: 1, a: 0.52 },
                    lineLimit: 1
                  })
                ], { spacing: 4, align: 'center' });
              }

              const existing = SuperIsland.components || {};
              SuperIsland.components = {
                ...existing,
                shortcutHint,
                inputComposer: function(opts) {
                  const options = opts || {};
                  const content = View.vstack([
                    View.inputBox(
                      String(options.placeholder ?? ''),
                      String(options.text ?? ''),
                      String(options.action ?? ''),
                      {
                        id: options.id ? String(options.id) : '',
                        autoFocus: options.autoFocus !== undefined ? !!options.autoFocus : true,
                        minHeight: options.minHeight !== undefined ? Number(options.minHeight) : 46,
                        showsEmojiButton: options.showsEmojiButton !== undefined ? !!options.showsEmojiButton : false
                      }
                    ),
                    options.error
                      ? View.text(String(options.error), {
                          style: 'footnote',
                          color: 'red',
                          lineLimit: 2
                        })
                      : (options.showsShortcutHint === false ? null : shortcutHint())
                  ], {
                    spacing: options.spacing !== undefined ? Number(options.spacing) : 4,
                    align: 'leading'
                  });

                  if (options.chrome === false) {
                    return content;
                  }

                  return View.cornerRadius(
                    View.background(
                      View.padding(
                        content,
                        { edges: 'all', amount: options.padding !== undefined ? Number(options.padding) : 6 }
                      ),
                      options.backgroundColor || { r: 0, g: 0, b: 0, a: 0.28 }
                    ),
                    options.cornerRadius !== undefined ? Number(options.cornerRadius) : 12
                  );
                }
              };
            })();
            """
        )
    }

    private func callLifecycleHook(named name: String) {
        guard let callback = moduleConfig?.forProperty(name), !callback.isUndefined else {
            return
        }
        invokeJS(name) { callback.call(withArguments: []) }
    }

    private func renderNode(from object: JSValue, key: String) -> ViewNode? {
        guard let callback = object.forProperty(key), !callback.isUndefined else {
            return nil
        }

        guard let result = invokeJS("view.\(key)()", { callback.call(withArguments: []) }) else {
            return .empty
        }

        return ViewNode.from(result) ?? .empty
    }

    @MainActor
    private func syncIslandState() {
        guard let islandNamespace else { return }

        let state: String
        switch AppState.shared.currentState {
        case .compact:
            state = "compact"
        case .expanded:
            state = "expanded"
        case .fullExpanded:
            state = "fullExpanded"
        }

        islandNamespace.setObject(state, forKeyedSubscript: "state" as NSString)
        islandNamespace.setObject(AppState.shared.activeModule == islandActivationModule, forKeyedSubscript: "isActive" as NSString)
    }

    private func scheduleTimer(callback: JSValue, milliseconds: Double, repeats: Bool) -> Int {
        let timerID = nextTimerID
        nextTimerID += 1

        let interval = max(0.01, milliseconds / 1000)
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: repeats) { [weak self] timer in
            guard let self else { return }
            self.invokeJS("timer(\(timerID))") { callback.call(withArguments: []) }
            if !repeats {
                self.timers.removeValue(forKey: timerID)
                timer.invalidate()
            }
        }

        RunLoop.main.add(timer, forMode: .common)
        timers[timerID] = timer
        return timerID
    }

    private func clearTimer(id: Int) {
        guard let timer = timers[id] else { return }
        timer.invalidate()
        timers.removeValue(forKey: id)
    }

    private func invalidateAllTimers() {
        timers.values.forEach { $0.invalidate() }
        timers.removeAll()
    }

    private func storeKey(for key: String) -> String {
        "extensions.\(extensionID).store.\(key)"
    }

    private func settingsKey(for key: String) -> String {
        "extensions.\(extensionID).settings.\(key)"
    }

    private func save(value: Any?, forKey key: String) {
        guard let value else {
            defaults.removeObject(forKey: key)
            return
        }

        if value is NSNull {
            defaults.removeObject(forKey: key)
            return
        }

        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: []) {
            defaults.set(data, forKey: key)
            return
        }

        if let propertyList = value as? NSString {
            defaults.set(propertyList, forKey: key)
        } else if let propertyList = value as? NSNumber {
            defaults.set(propertyList, forKey: key)
        } else if let propertyList = value as? NSArray {
            defaults.set(propertyList, forKey: key)
        } else if let propertyList = value as? NSDictionary {
            defaults.set(propertyList, forKey: key)
        } else {
            defaults.set(String(describing: value), forKey: key)
        }
    }

    private func jsValueFromStoredObject(_ value: Any) -> JSValue? {
        if let data = value as? Data,
           let json = try? JSONSerialization.jsonObject(with: data) {
            return JSValue(object: json, in: context)
        }
        return JSValue(object: value, in: context)
    }

    private func fetchSync(urlString: String, options: JSValue?) -> JSValue? {
        guard manifest.permissions.contains("network") else {
            context.exception = JSValue(newErrorFromMessage: "Permission denied: network", in: context)
            return JSValue(nullIn: context)
        }

        guard let url = URL(string: urlString) else {
            return JSValue(object: ["status": 0, "data": NSNull(), "text": "", "error": "Invalid URL"], in: context)
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if let options {
            if let method = jsOptionalString(options, key: "method"), !method.isEmpty {
                request.httpMethod = method
            }
            if let body = jsOptionalString(options, key: "body") {
                request.httpBody = body.data(using: .utf8)
            }
            if let headers = options.forProperty("headers")?.toDictionary() as? [String: String] {
                for (key, value) in headers {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }
        }

        let semaphore = DispatchSemaphore(value: 0)
        var responseStatus = 0
        var responseData = Data()
        var responseError: Error?

        let task = extensionURLSession.dataTask(with: request) { data, response, error in
            responseData = data ?? Data()
            responseStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
            responseError = error
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 15)

        if let responseError {
            return JSValue(object: [
                "status": responseStatus,
                "data": NSNull(),
                "text": "",
                "error": responseError.localizedDescription
            ], in: context)
        }

        let text = String(data: responseData, encoding: .utf8) ?? ""
        let parsedJSON = try? JSONSerialization.jsonObject(with: responseData)

        return JSValue(object: [
            "status": responseStatus,
            "data": parsedJSON ?? NSNull(),
            "text": text
        ], in: context)
    }

    private func sendNotification(
        title: String,
        body: String,
        sound: Bool,
        appName: String?,
        bundleIdentifier: String?,
        senderName: String?,
        previewText: String?,
        avatarURL: String?,
        appIconURL: String?,
        sourceID: String?,
        tapAction: NotificationTapAction?,
        shouldShowSystemNotification: Bool
    ) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        if manifest.capabilities.notificationFeed {
            let resolvedAppName = appName ?? manifest.name
            let resolvedBundleIdentifier = bundleIdentifier ?? extensionID
            let resolvedSenderName = senderName ?? (title.isEmpty ? nil : title)
            let resolvedPreviewText = previewText ?? (body.isEmpty ? nil : body)
            let resolvedTitle = resolvedSenderName ?? (title.isEmpty ? resolvedAppName : title)
            let resolvedBody = resolvedPreviewText ?? body
            let resolvedAppIconURL = appIconURL ?? manifest.iconURL?.absoluteString
            let resolvedSourceID = sourceID ?? "extension:\(extensionID):\(UUID().uuidString)"

            Task { @MainActor in
                let notification = IslandNotification(
                    sourceID: resolvedSourceID,
                    appName: resolvedAppName,
                    bundleIdentifier: resolvedBundleIdentifier,
                    appIcon: "app.badge",
                    appIconURL: resolvedAppIconURL,
                    title: resolvedTitle,
                    body: resolvedBody,
                    senderName: resolvedSenderName,
                    previewText: resolvedPreviewText,
                    avatarURL: avatarURL,
                    timestamp: Date(),
                    tapAction: tapAction
                )
                NotificationManager.shared.addNotification(notification)
            }
        }

        if shouldShowSystemNotification {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = sound ? .default : nil

            let request = UNNotificationRequest(
                identifier: "superisland.\(extensionID).\(UUID().uuidString)",
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
            )
            center.add(request)
        }
    }

    @MainActor
    private func latestNotificationPayload() -> [String: Any]? {
        guard let latest = NotificationManager.shared.latestNotification else {
            return nil
        }
        return notificationPayload(from: latest)
    }

    @MainActor
    private func recentNotificationPayloads(limit: Int) -> [[String: Any]] {
        NotificationManager.shared.recentNotifications
            .prefix(limit)
            .map(notificationPayload(from:))
    }

    private func notificationPayload(from notification: IslandNotification) -> [String: Any] {
        [
            "id": notification.sourceID,
            "localID": notification.id,
            "appName": notification.appName,
            "bundleIdentifier": notification.bundleIdentifier as Any,
            "appIcon": notification.appIcon,
            "appIconURL": notification.appIconURL as Any,
            "title": notification.title,
            "body": notification.body,
            "senderName": notification.senderName as Any,
            "previewText": notification.previewText as Any,
            "avatarURL": notification.avatarURL as Any,
            "timestamp": Int(notification.timestamp.timeIntervalSince1970)
        ]
    }

    private func normalizedText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowered = trimmed.lowercased()
        if lowered == "undefined" || lowered == "null" || lowered == "(null)" {
            return nil
        }

        return trimmed
    }

    private func notificationTapAction(from value: JSValue?) -> NotificationTapAction? {
        guard let value, !value.isUndefined, !value.isNull else {
            return nil
        }

        guard let actionID = normalizedText(value.forProperty("action")?.toString()) else {
            return nil
        }

        let resolvedExtensionID = normalizedText(value.forProperty("extensionID")?.toString()) ?? extensionID
        let presentationRaw = normalizedText(value.forProperty("presentation")?.toString())
            ?? NotificationActionPresentation.fullExpanded.rawValue
        let presentation = NotificationActionPresentation(rawValue: presentationRaw) ?? .fullExpanded

        var payload: [String: String] = [:]
        if let rawPayload = value.forProperty("payload")?.toDictionary() {
            for (key, rawValue) in rawPayload {
                let payloadKey = String(describing: key).trimmingCharacters(in: .whitespacesAndNewlines)
                let payloadValue = normalizedText(String(describing: rawValue))
                guard !payloadKey.isEmpty, let payloadValue else { continue }
                payload[payloadKey] = payloadValue
            }
        }

        return NotificationTapAction(
            extensionID: resolvedExtensionID,
            actionID: actionID,
            payload: payload,
            presentation: presentation
        )
    }

    private func normalizedResourceURLString(_ value: String?) -> String? {
        guard let raw = normalizedText(value) else { return nil }
        if raw.hasPrefix("file://") || raw.hasPrefix("http://") || raw.hasPrefix("https://") || raw.hasPrefix("data:") {
            return raw
        }
        if raw.hasPrefix("/") {
            return URL(fileURLWithPath: raw).absoluteString
        }
        return nil
    }
}

/// Safely read a String option from a JS options dict, returning nil when the
/// property is undefined or null. Without this check, `.toString()` on an
/// undefined JSValue returns the literal string "undefined", which then gets
/// set as request.httpBody for GET requests — CFNetwork rejects those with
/// NSURLErrorDataLengthExceedsMaximum (-1103) for HTTPS hosts.
fileprivate func jsOptionalString(_ options: JSValue?, key: String) -> String? {
    guard let options, !options.isUndefined, !options.isNull else { return nil }
    guard let value = options.forProperty(key) else { return nil }
    if value.isUndefined || value.isNull { return nil }
    let str = value.toString()
    if str == nil || str == "undefined" || str == "null" { return nil }
    return str
}

/// Dedicated URLSession for extension HTTP requests. Uses an ephemeral
/// configuration (no URLCache) because URLSession.shared's default cache path
/// triggers NSURLErrorDataLengthExceedsMaximum on some macOS builds even for
/// tiny localhost responses. Ephemeral sessions skip the cache entirely and
/// ignore any corrupted cookie / credential state, fixing the issue.
private let extensionURLSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    config.urlCache = nil
    config.timeoutIntervalForRequest = 15
    config.timeoutIntervalForResource = 30
    config.waitsForConnectivity = false
    return URLSession(configuration: config)
}()

/// Thread-safe HTTP response payload used by the async fetch path. Lives
/// outside the runtime so it can be constructed off the main thread without
/// touching JSContext (which is single-threaded per context).
private struct AsyncFetchResult {
    let status: Int
    let data: Any
    let text: String
    let error: String?

    func asDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "status": status,
            "data": data,
            "text": text
        ]
        if let error {
            dict["error"] = error
        }
        return dict
    }

    static func perform(
        urlString: String,
        method: String?,
        body: String?,
        headers: [String: String]?,
        hasPermission: Bool
    ) -> AsyncFetchResult {
        guard hasPermission else {
            return AsyncFetchResult(status: 0, data: NSNull(), text: "", error: "Permission denied: network")
        }
        guard let url = URL(string: urlString) else {
            return AsyncFetchResult(status: 0, data: NSNull(), text: "", error: "Invalid URL")
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if let method, !method.isEmpty {
            request.httpMethod = method
        }
        if let body {
            request.httpBody = body.data(using: .utf8)
        }
        if let headers {
            for (k, v) in headers {
                request.setValue(v, forHTTPHeaderField: k)
            }
        }

        let semaphore = DispatchSemaphore(value: 0)
        var responseStatus = 0
        var responseData = Data()
        var responseError: Error?
        extensionURLSession.dataTask(with: request) { data, response, error in
            responseData = data ?? Data()
            responseStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
            responseError = error
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 15)

        if let responseError {
            return AsyncFetchResult(
                status: responseStatus,
                data: NSNull(),
                text: "",
                error: responseError.localizedDescription
            )
        }
        let text = String(data: responseData, encoding: .utf8) ?? ""
        let parsed = (try? JSONSerialization.jsonObject(with: responseData)) ?? NSNull()
        return AsyncFetchResult(status: responseStatus, data: parsed, text: text, error: nil)
    }
}
