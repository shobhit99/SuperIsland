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
        injectAPI()

        guard let script = try? String(contentsOf: manifest.entryURL, encoding: .utf8) else {
            throw RuntimeError.scriptReadFailed(manifest.entryURL)
        }

        context.evaluateScript(script, withSourceURL: manifest.entryURL)

        if let exception = context.exception?.toString() {
            throw RuntimeError.scriptEvaluationFailed(exception)
        }
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
        if let minimalCompact = config.forProperty("minimalCompact"), !minimalCompact.isUndefined, !minimalCompact.isNull {
            minimalLeading = renderNode(from: minimalCompact, key: "leading")
            minimalTrailing = renderNode(from: minimalCompact, key: "trailing")
        }

        return ExtensionViewState(
            compact: compact,
            expanded: expanded,
            fullExpanded: fullExpanded,
            minimalLeading: minimalLeading,
            minimalTrailing: minimalTrailing
        )
    }

    @MainActor
    func handleAction(actionID: String, value: Any?) {
        syncIslandState()

        guard let callback = moduleConfig?.forProperty("onAction"), !callback.isUndefined else {
            return
        }

        if let value {
            callback.call(withArguments: [actionID, value])
        } else {
            callback.call(withArguments: [actionID])
        }
    }

    private func injectAPI() {
        let dynamicIsland = JSValue(newObjectIn: context)!
        context.setObject(dynamicIsland, forKeyedSubscript: "DynamicIsland" as NSString)

        injectModuleRegistration(into: dynamicIsland)
        injectStore(into: dynamicIsland)
        injectSettings(into: dynamicIsland)
        injectIslandControls(into: dynamicIsland)
        injectNotifications(into: dynamicIsland)
        injectHTTP(into: dynamicIsland)
        injectSystem(into: dynamicIsland)
        injectFeedback(into: dynamicIsland)
        injectConsole(into: dynamicIsland)
        injectTimers()
        injectViewHelpers()
    }

    private func injectModuleRegistration(into dynamicIsland: JSValue) {
        let registerModule: @convention(block) (JSValue) -> Void = { [weak self] config in
            guard let self else { return }
            self.moduleConfig = config
            ExtensionLogger.shared.log(self.extensionID, .info, "Module registered")
        }
        dynamicIsland.setObject(registerModule, forKeyedSubscript: "registerModule" as NSString)
    }

    private func injectStore(into dynamicIsland: JSValue) {
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
        dynamicIsland.setObject(store, forKeyedSubscript: "store" as NSString)
    }

    private func injectSettings(into dynamicIsland: JSValue) {
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
        dynamicIsland.setObject(settings, forKeyedSubscript: "settings" as NSString)
    }

    private func injectIslandControls(into dynamicIsland: JSValue) {
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
        dynamicIsland.setObject(island, forKeyedSubscript: "island" as NSString)
    }

    private func injectNotifications(into dynamicIsland: JSValue) {
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
        dynamicIsland.setObject(notifications, forKeyedSubscript: "notifications" as NSString)
    }

    private func injectHTTP(into dynamicIsland: JSValue) {
        let fetchSync: @convention(block) (String, JSValue?) -> JSValue? = { [weak self] urlString, options in
            guard let self else { return nil }
            return self.fetchSync(urlString: urlString, options: options)
        }

        dynamicIsland.setObject(fetchSync, forKeyedSubscript: "__fetchSync" as NSString)

        if manifest.permissions.contains("network") {
            context.evaluateScript(
                "DynamicIsland.http = { fetch: function(url, options) { return Promise.resolve(DynamicIsland.__fetchSync(url, options)); } };"
            )
        } else {
            context.evaluateScript(
                "DynamicIsland.http = { fetch: function() { throw new Error('Permission denied: network'); } };"
            )
        }
    }

    private func injectSystem(into dynamicIsland: JSValue) {
        let system = JSValue(newObjectIn: context)!

        let getAIUsage: @convention(block) () -> JSValue? = { [weak self] in
            guard let self else { return nil }
            guard self.manifest.permissions.contains("usage") else {
                return JSValue(nullIn: self.context)
            }
            return JSValue(object: AIUsageProvider.snapshot(), in: self.context)
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
        system.setObject(getLatestNotification, forKeyedSubscript: "getLatestNotification" as NSString)
        system.setObject(getRecentNotifications, forKeyedSubscript: "getRecentNotifications" as NSString)
        system.setObject(getWhatsAppWeb, forKeyedSubscript: "getWhatsAppWeb" as NSString)
        system.setObject(startWhatsAppWeb, forKeyedSubscript: "startWhatsAppWeb" as NSString)
        system.setObject(refreshWhatsAppWebQR, forKeyedSubscript: "refreshWhatsAppWebQR" as NSString)
        system.setObject(sendWhatsAppWebMessage, forKeyedSubscript: "sendWhatsAppWebMessage" as NSString)
        system.setObject(sendWhatsAppWebMessageAsync, forKeyedSubscript: "sendWhatsAppWebMessageAsync" as NSString)
        system.setObject(dismissNotification, forKeyedSubscript: "dismissNotification" as NSString)
        system.setObject(closePresentedInteraction, forKeyedSubscript: "closePresentedInteraction" as NSString)
        dynamicIsland.setObject(system, forKeyedSubscript: "system" as NSString)
    }

    private func injectFeedback(into dynamicIsland: JSValue) {
        let playFeedback: @convention(block) (String) -> Void = { type in
            switch type {
            case "success":
                NSSound(named: "Glass")?.play()
            case "warning":
                NSSound(named: "Funk")?.play()
            case "error":
                NSSound(named: "Basso")?.play()
            case "selection":
                NSSound(named: "Pop")?.play()
            default:
                NSSound.beep()
            }
        }

        let openURL: @convention(block) (String) -> Void = { urlString in
            guard let url = URL(string: urlString) else { return }
            NSWorkspace.shared.open(url)
        }

        dynamicIsland.setObject(playFeedback, forKeyedSubscript: "playFeedback" as NSString)
        dynamicIsland.setObject(openURL, forKeyedSubscript: "openURL" as NSString)
    }

    private func injectConsole(into dynamicIsland: JSValue) {
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

        dynamicIsland.setObject(logInfo, forKeyedSubscript: "__log" as NSString)
        dynamicIsland.setObject(logWarn, forKeyedSubscript: "__warn" as NSString)
        dynamicIsland.setObject(logError, forKeyedSubscript: "__error" as NSString)

        context.evaluateScript(
            """
            globalThis.console = {
              log: function() { DynamicIsland.__log(Array.from(arguments).map(String).join(' ')); },
              warn: function() { DynamicIsland.__warn(Array.from(arguments).map(String).join(' ')); },
              error: function() { DynamicIsland.__error(Array.from(arguments).map(String).join(' ')); }
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

    private func callLifecycleHook(named name: String) {
        guard let callback = moduleConfig?.forProperty(name), !callback.isUndefined else {
            return
        }
        callback.call(withArguments: [])
    }

    private func renderNode(from object: JSValue, key: String) -> ViewNode? {
        guard let callback = object.forProperty(key), !callback.isUndefined else {
            return nil
        }

        guard let result = callback.call(withArguments: []) else {
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
            callback.call(withArguments: [])
            if !repeats {
                self?.timers.removeValue(forKey: timerID)
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
        if let options {
            if let method = options.forProperty("method")?.toString(), !method.isEmpty {
                request.httpMethod = method
            }
            if let body = options.forProperty("body")?.toString() {
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

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
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
                identifier: "dynamicisland.\(extensionID).\(UUID().uuidString)",
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
