import AppKit
import JavaScriptCore
import SwiftUI
import UserNotifications

@MainActor
final class ExtensionJSRuntime {
    let context: JSContext
    let manifest: ExtensionManifest

    private var compactCallback: JSValue?
    private var expandedCallback: JSValue?
    private var fullExpandedCallback: JSValue?
    private var minimalCompactLeadingCallback: JSValue?
    private var minimalCompactTrailingCallback: JSValue?
    private var onActivateCallback: JSValue?
    private var onDeactivateCallback: JSValue?
    private var onActionCallback: JSValue?
    private var timers: [Int: Timer] = [:]
    private var nextTimerID = 1

    init(manifest: ExtensionManifest) throws {
        self.manifest = manifest
        guard let context = JSContext() else {
            throw NSError(domain: "ExtensionJSRuntime", code: 1)
        }
        self.context = context

        injectAPI()
        injectViewHelpers()
        ExtensionSandbox.configureContext(context, extensionID: manifest.id, permissions: manifest.permissions)

        let script = try String(contentsOf: manifest.mainFileURL)
        context.evaluateScript(script, withSourceURL: manifest.mainFileURL)
        onActivateCallback?.call(withArguments: [])
    }

    deinit {
        Task { @MainActor in
            cleanup()
        }
    }

    func fetchState() -> ExtensionViewState? {
        updateIslandRuntimeState()

        guard let compactCallback, let expandedCallback else {
            return nil
        }

        let compactNode = ExtensionViewNode.from(compactCallback.call(withArguments: [])) ?? .empty
        let expandedNode = ExtensionViewNode.from(expandedCallback.call(withArguments: [])) ?? .empty
        let fullExpandedNode = ExtensionViewNode.from(fullExpandedCallback?.call(withArguments: []))
        let minimalLeadingNode = ExtensionViewNode.from(minimalCompactLeadingCallback?.call(withArguments: []))
        let minimalTrailingNode = ExtensionViewNode.from(minimalCompactTrailingCallback?.call(withArguments: []))

        return ExtensionViewState(
            compact: compactNode,
            expanded: expandedNode,
            fullExpanded: fullExpandedNode,
            minimalLeading: minimalLeadingNode,
            minimalTrailing: minimalTrailingNode
        )
    }

    func handleAction(actionID: String, value: Any?) {
        onActionCallback?.call(withArguments: [actionID, value ?? NSNull()])
    }

    func cleanup() {
        onDeactivateCallback?.call(withArguments: [])
        timers.values.forEach { $0.invalidate() }
        timers.removeAll()
    }

    private func injectAPI() {
        let di = JSValue(newObjectIn: context)!
        context.setObject(di, forKeyedSubscript: "DynamicIsland" as NSString)

        let register: @convention(block) (JSValue) -> Void = { [weak self] config in
            self?.handleRegistration(config)
        }
        di.setObject(register, forKeyedSubscript: "registerModule" as NSString)

        let store = JSValue(newObjectIn: context)!
        let storeGet: @convention(block) (String) -> Any? = { [weak self] key in
            self?.userDefaults.object(forKey: self?.storageKey(for: key) ?? key)
        }
        let storeSet: @convention(block) (String, JSValue) -> Void = { [weak self] key, value in
            self?.userDefaults.set(self?.sanitize(value: value), forKey: self?.storageKey(for: key) ?? key)
        }
        store.setObject(storeGet, forKeyedSubscript: "get" as NSString)
        store.setObject(storeSet, forKeyedSubscript: "set" as NSString)
        di.setObject(store, forKeyedSubscript: "store" as NSString)

        let settings = JSValue(newObjectIn: context)!
        let settingsGet: @convention(block) (String) -> Any? = { [weak self] key in
            guard let self else { return nil }
            return ExtensionManager.shared.settingValue(for: self.manifest.id, key: key)
        }
        let settingsSet: @convention(block) (String, JSValue) -> Void = { [weak self] key, value in
            guard let self else { return }
            ExtensionManager.shared.setSettingValue(self.sanitize(value: value), for: self.manifest.id, key: key)
        }
        settings.setObject(settingsGet, forKeyedSubscript: "get" as NSString)
        settings.setObject(settingsSet, forKeyedSubscript: "set" as NSString)
        di.setObject(settings, forKeyedSubscript: "settings" as NSString)

        let system = JSValue(newObjectIn: context)!
        let getAIUsage: @convention(block) () -> Any = { [weak self] in
            guard let self, self.manifest.permissions.contains("usage") else {
                return NSNull()
            }
            return AIUsageProvider.shared.snapshotDictionary()
        }
        system.setObject(getAIUsage, forKeyedSubscript: "getAIUsage" as NSString)
        di.setObject(system, forKeyedSubscript: "system" as NSString)

        let island = JSValue(newObjectIn: context)!
        let activate: @convention(block) (Bool) -> Void = { [weak self] autoDismiss in
            guard let self else { return }
            AppState.shared.showHUD(module: .extension_(self.manifest.id), autoDismiss: autoDismiss)
        }
        let dismiss: @convention(block) () -> Void = {
            AppState.shared.dismiss()
        }
        island.setObject(activate, forKeyedSubscript: "activate" as NSString)
        island.setObject(dismiss, forKeyedSubscript: "dismiss" as NSString)
        island.setObject("compact", forKeyedSubscript: "state" as NSString)
        island.setObject(false, forKeyedSubscript: "isActive" as NSString)
        di.setObject(island, forKeyedSubscript: "island" as NSString)

        let notifications = JSValue(newObjectIn: context)!
        let notify: @convention(block) (JSValue) -> Void = { [weak self] options in
            self?.sendNotification(options: options)
        }
        notifications.setObject(notify, forKeyedSubscript: "send" as NSString)
        di.setObject(notifications, forKeyedSubscript: "notifications" as NSString)

        let httpBridge: @convention(block) (String, JSValue?, JSValue, JSValue) -> Void = { [weak self] urlString, options, resolve, reject in
            self?.performFetch(urlString: urlString, options: options, resolve: resolve, reject: reject)
        }
        context.setObject(httpBridge, forKeyedSubscript: "__diFetch" as NSString)

        let playFeedback: @convention(block) (String) -> Void = { feedback in
            let performer = NSHapticFeedbackManager.defaultPerformer
            let pattern: NSHapticFeedbackManager.FeedbackPattern = feedback == "error" ? .levelChange : .alignment
            performer.perform(pattern, performanceTime: .default)
        }
        di.setObject(playFeedback, forKeyedSubscript: "playFeedback" as NSString)

        let openURL: @convention(block) (String) -> Void = { urlString in
            guard let url = URL(string: urlString) else { return }
            NSWorkspace.shared.open(url)
        }
        di.setObject(openURL, forKeyedSubscript: "openURL" as NSString)

        injectTimers()
        injectConsole()
        injectHTTPWrapper()
    }

    private func injectViewHelpers() {
        context.evaluateScript(
            """
            globalThis.View = {
              hstack: function(children, opts) { return { type: "hstack", spacing: (opts && opts.spacing) || 8, align: opts && opts.align, children: children.filter(Boolean) }; },
              vstack: function(children, opts) { return { type: "vstack", spacing: (opts && opts.spacing) || 4, align: opts && opts.align, children: children.filter(Boolean) }; },
              zstack: function(children) { return { type: "zstack", children: children.filter(Boolean) }; },
              spacer: function(minLength) { return { type: "spacer", minLength: minLength }; },
              text: function(value, opts) { return { type: "text", value: value, style: opts && opts.style || "body", color: opts && opts.color }; },
              icon: function(name, opts) { return { type: "icon", name: name, size: opts && opts.size || 14, color: opts && opts.color }; },
              image: function(url, opts) { return Object.assign({ type: "image", url: url }, opts || {}); },
              progress: function(value, opts) { return { type: "progress", value: value, total: opts && opts.total || 1, color: opts && opts.color }; },
              circularProgress: function(value, opts) { return { type: "circular-progress", value: value, total: opts && opts.total || 1, lineWidth: opts && opts.lineWidth || 3, color: opts && opts.color }; },
              gauge: function(value, opts) { return Object.assign({ type: "gauge", value: value }, opts || {}); },
              divider: function() { return { type: "divider" }; },
              button: function(label, action) { return { type: "button", label: label, action: action }; },
              toggle: function(isOn, label, action) { return { type: "toggle", isOn: isOn, label: label, action: action }; },
              slider: function(value, min, max, action) { return { type: "slider", value: value, min: min, max: max, action: action }; },
              padding: function(child, opts) { return { type: "padding", child: child, edges: opts && opts.edges || "all", amount: opts && opts.amount || 8 }; },
              frame: function(child, opts) { return Object.assign({ type: "frame", child: child }, opts || {}); },
              opacity: function(child, value) { return { type: "opacity", child: child, value: value }; },
              background: function(child, color) { return { type: "background", child: child, color: color }; },
              cornerRadius: function(child, radius) { return { type: "cornerRadius", child: child, radius: radius }; },
              animate: function(child, kind) { return { type: "animation", child: child, kind: kind }; },
              when: function(condition, thenNode, otherwiseNode) { return condition ? thenNode : (otherwiseNode || null); },
              timerText: function(seconds, opts) {
                var minutes = Math.floor(seconds / 60);
                var remaining = seconds % 60;
                return {
                  type: "text",
                  value: String(minutes).padStart(2, "0") + ":" + String(remaining).padStart(2, "0"),
                  style: opts && opts.style || "monospaced",
                  color: "white"
                };
              }
            };
            """
        )
    }

    private func injectConsole() {
        let log: @convention(block) (String) -> Void = { [weak self] message in
            guard let self else { return }
            ExtensionLogger.shared.log(self.manifest.id, .info, message)
        }
        let warn: @convention(block) (String) -> Void = { [weak self] message in
            guard let self else { return }
            ExtensionLogger.shared.log(self.manifest.id, .warning, message)
        }
        let error: @convention(block) (String) -> Void = { [weak self] message in
            guard let self else { return }
            ExtensionLogger.shared.log(self.manifest.id, .error, message)
        }

        context.setObject(log, forKeyedSubscript: "__diConsoleLog" as NSString)
        context.setObject(warn, forKeyedSubscript: "__diConsoleWarn" as NSString)
        context.setObject(error, forKeyedSubscript: "__diConsoleError" as NSString)
        context.evaluateScript(
            """
            globalThis.console = {
              log: function() { __diConsoleLog(Array.prototype.join.call(arguments, " ")); },
              warn: function() { __diConsoleWarn(Array.prototype.join.call(arguments, " ")); },
              error: function() { __diConsoleError(Array.prototype.join.call(arguments, " ")); }
            };
            """
        )
    }

    private func injectTimers() {
        let setIntervalBlock: @convention(block) (JSValue, Double) -> Int = { [weak self] callback, ms in
            self?.scheduleTimer(callback: callback, interval: ms / 1000, repeats: true) ?? 0
        }
        let setTimeoutBlock: @convention(block) (JSValue, Double) -> Int = { [weak self] callback, ms in
            self?.scheduleTimer(callback: callback, interval: ms / 1000, repeats: false) ?? 0
        }
        let clearBlock: @convention(block) (Int) -> Void = { [weak self] timerID in
            self?.invalidateTimer(timerID)
        }

        context.setObject(setIntervalBlock, forKeyedSubscript: "setInterval" as NSString)
        context.setObject(setTimeoutBlock, forKeyedSubscript: "setTimeout" as NSString)
        context.setObject(clearBlock, forKeyedSubscript: "clearInterval" as NSString)
        context.setObject(clearBlock, forKeyedSubscript: "clearTimeout" as NSString)
    }

    private func injectHTTPWrapper() {
        context.evaluateScript(
            """
            globalThis.DynamicIsland.http = {
              fetch: function(url, options) {
                return new Promise(function(resolve, reject) {
                  __diFetch(url, options || null, resolve, reject);
                });
              }
            };
            """
        )
    }

    private func handleRegistration(_ config: JSValue) {
        compactCallback = config.forProperty("compact")
        expandedCallback = config.forProperty("expanded")
        fullExpandedCallback = config.forProperty("fullExpanded")
        let minimalCompact = config.forProperty("minimalCompact")
        minimalCompactLeadingCallback = minimalCompact?.forProperty("leading")
        minimalCompactTrailingCallback = minimalCompact?.forProperty("trailing")
        onActivateCallback = config.forProperty("onActivate")
        onDeactivateCallback = config.forProperty("onDeactivate")
        onActionCallback = config.forProperty("onAction")
    }

    private var userDefaults: UserDefaults {
        .standard
    }

    private func storageKey(for key: String) -> String {
        "extension.storage.\(manifest.id).\(key)"
    }

    private func sanitize(value: JSValue) -> Any? {
        if value.isNull || value.isUndefined {
            return nil
        }

        if let bool = value.toBool() as Bool? {
            return bool
        }

        if let number = value.toNumber() {
            return number
        }

        if let string = value.toString() {
            return string
        }

        return value.toObject()
    }

    private func sendNotification(options: JSValue) {
        let title = options.forProperty("title")?.toString() ?? manifest.name
        let body = options.forProperty("body")?.toString() ?? ""
        let sound = options.forProperty("sound")?.toBool() ?? true

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound {
            content.sound = .default
        }

        let request = UNNotificationRequest(
            identifier: "\(manifest.id).\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            UNUserNotificationCenter.current().add(request)
        }
    }

    private func performFetch(urlString: String, options: JSValue?, resolve: JSValue, reject: JSValue) {
        guard manifest.permissions.contains("network") else {
            reject.call(withArguments: ["Permission denied: network"])
            return
        }

        guard let url = URL(string: urlString) else {
            reject.call(withArguments: ["Invalid URL"])
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = options?.forProperty("method")?.toString() ?? "GET"

        if let headers = options?.forProperty("headers")?.toDictionary() as? [String: String] {
            headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        }

        if let body = options?.forProperty("body")?.toString() {
            request.httpBody = body.data(using: .utf8)
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error {
                    reject.call(withArguments: [error.localizedDescription])
                    return
                }

                let httpResponse = response as? HTTPURLResponse
                let rawText = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let json: Any
                if let data,
                   let parsed = try? JSONSerialization.jsonObject(with: data) {
                    json = parsed
                } else {
                    json = rawText
                }

                resolve.call(withArguments: [[
                    "status": httpResponse?.statusCode ?? 0,
                    "data": json,
                    "text": rawText,
                ]])
            }
        }
        .resume()
    }

    private func scheduleTimer(callback: JSValue, interval: TimeInterval, repeats: Bool) -> Int {
        let timerID = nextTimerID
        nextTimerID += 1

        let timer = Timer.scheduledTimer(withTimeInterval: max(0.01, interval), repeats: repeats) { [weak self] timer in
            callback.call(withArguments: [])
            if !repeats {
                self?.timers.removeValue(forKey: timerID)
                timer.invalidate()
            }
        }
        timers[timerID] = timer
        return timerID
    }

    private func invalidateTimer(_ timerID: Int) {
        timers[timerID]?.invalidate()
        timers.removeValue(forKey: timerID)
    }

    private func updateIslandRuntimeState() {
        guard let island = context.objectForKeyedSubscript("DynamicIsland")?.forProperty("island") else {
            return
        }

        let state: String
        switch AppState.shared.currentState {
        case .compact:
            state = "compact"
        case .expanded:
            state = "expanded"
        case .fullExpanded:
            state = "fullExpanded"
        }

        island.setObject(state, forKeyedSubscript: "state" as NSString)
        island.setObject(AppState.shared.activeModule == .extension_(manifest.id), forKeyedSubscript: "isActive" as NSString)
    }
}
