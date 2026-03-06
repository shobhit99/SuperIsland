# DynamicIsland Extension SDK — JavaScript API

## Context

DynamicIsland is a native macOS app (Swift/SwiftUI, macOS 14+) that transforms the MacBook notch area into an interactive Dynamic Island. It currently has 8 built-in modules: Now Playing, Volume HUD, Brightness HUD, Battery, Connectivity, Calendar, Weather, and Notifications.

We want to make DynamicIsland **hackable and extensible** — allowing the community to build, distribute, and install third-party extensions using **JavaScript/TypeScript**, similar to how Raycast extensions work. Extensions run inside a JavaScriptCore sandbox and describe their UI declaratively — the host app renders them natively in SwiftUI.

Current repo layout:
- `ExtensionHost/` contains the host-side runtime used by the macOS app
- `Extensions/` contains unpacked local/sample extensions discovered during development

---

## Goal

Build a complete JS-based Extension SDK and Extension Store. Extensions are simple JS/TS projects that provide:
- A **compact view** (fits in the pill: ~188×34pt)
- An optional **minimal notch view** for notched Macs, with one leading item and one trailing item while the center stays hidden in the hardware notch
- An **expanded view** (drawer: 360×80pt)
- A **full expanded view** (detail panel: 400×200pt)
- A **background service** that can poll, listen, or compute data
- Optional **settings UI** via a declarative schema

Examples of extensions the community could build:
- Pomodoro / Focus timer with countdown in compact, controls in expanded
- Spotify lyrics overlay
- CPU/RAM/Disk monitor (like iStat)
- Stock ticker / Crypto price tracker
- GitHub notifications / PR status
- Clipboard history
- Shortcut launcher
- Meeting countdown (Zoom/Teams)
- Habit tracker
- Air quality / UV index
- Package delivery tracking
- Smart home device controls (HomeKit)
- Tailscale / VPN status

---

## Current Architecture (for reference)

### State Machine
```
IslandState: .compact (188×34) → .expanded (360×80) → .fullExpanded (400×200)
```

### Module Pattern
Every built-in module follows this pattern:
1. **Manager** (`ObservableObject` singleton) — owns `@Published` state, runs background logic
2. **CompactView** — SwiftUI view rendered in the pill
3. **ExpandedView** — SwiftUI view rendered in the drawer
4. **Registration** — enum case in `ModuleType`, switch-case routing in `CompactView.swift`, `ExpandedView.swift`, `FullExpandedView.swift`

### Activation
- `AppState.shared.setActiveModule(.module)` — sets the active module
- `AppState.shared.showHUD(module:, autoDismiss:)` — shows module and auto-collapses after delay
- `AppState.shared.cycleModule(forward:)` — swipe left/right to cycle

### Sizing & Rendering
- Island panel is a transparent `NSPanel` (`.nonactivatingPanel`, `canBecomeKey=false`, `.statusBar` level)
- Panel is always sized to max (420×260), SwiftUI handles visual sizing within
- PillShape animates corner radius between states
- Spring animations: `.spring(response: 0.35, dampingFraction: 0.75)` for transitions

---

## What to Build

### Phase 1: JavaScriptCore Runtime & Extension API

#### 1.1 Extension Package Format

Extensions are simple directories (no compilation needed):

```
pomodoro/
├── manifest.json          # Extension metadata + permissions
├── index.js               # Main entry point (or index.ts → compiled)
├── assets/
│   ├── icon.png           # 64×64 extension icon
│   └── icon-compact.png   # 16×16 for compact view
└── settings.json          # Settings schema (optional)
```

Published extensions are distributed as `.zip` files. The CLI compiles TS → JS before packaging.

#### 1.2 Extension Manifest (`manifest.json`)

```json
{
  "id": "com.developer.pomodoro",
  "name": "Pomodoro Timer",
  "version": "1.0.0",
  "minAppVersion": "1.0.0",
  "main": "index.js",
  "author": {
    "name": "Jane Developer",
    "url": "https://github.com/jane/pomodoro-island"
  },
  "description": "Focus timer with Pomodoro technique. Shows countdown in compact view, controls in expanded.",
  "icon": "assets/icon.png",
  "license": "MIT",
  "categories": ["productivity", "timer"],
  "permissions": [
    "notifications",
    "storage"
  ],
  "capabilities": {
    "compact": true,
    "expanded": true,
    "fullExpanded": true,
    "minimalCompact": true,
    "backgroundRefresh": true,
    "settings": true,
    "notificationFeed": false
  },
  "refreshInterval": 1.0,
  "activationTriggers": ["manual", "timer"]
}
```

Supported permissions currently:
- `notifications` — send macOS notifications and read mirrored notification feed via `DynamicIsland.system`
- `storage` — persist extension-scoped key/value state
- `network` — make requests through `DynamicIsland.http.fetch()`
- `usage` — read local Codex and Claude usage summaries through `DynamicIsland.system.getAIUsage()`

`capabilities.notificationFeed`:
- When `true`, the extension is not shown as a separate module in island cycling.
- `DynamicIsland.island.activate()` targets the shared Notifications module.
- `DynamicIsland.notifications.send(...)` is mirrored into the shared Dynamic Island notifications feed.

#### 1.3 JavaScriptCore Bridge (Swift Side)

The host app creates one `JSContext` per extension. The following globals are injected before the extension's `index.js` is evaluated:

```swift
/// Swift side: sets up the JSContext for an extension.
final class ExtensionJSRuntime {
    let context: JSContext
    let extensionID: String
    private var stateCallback: JSValue?
    private var actionCallback: JSValue?

    init(extensionID: String, bundle: URL) {
        context = JSContext()!
        self.extensionID = extensionID

        // Inject the DynamicIsland global API
        injectAPI()

        // Load the extension's index.js
        let script = try! String(contentsOf: bundle.appending(path: "index.js"))
        context.evaluateScript(script)
    }

    private func injectAPI() {
        // The DynamicIsland global namespace
        let di = JSValue(newObjectIn: context)!
        context.setObject(di, forKeyedSubscript: "DynamicIsland" as NSString)

        // DynamicIsland.registerModule(config)
        let register: @convention(block) (JSValue) -> Void = { [weak self] config in
            self?.handleRegistration(config)
        }
        di.setObject(register, forKeyedSubscript: "registerModule" as NSString)

        // DynamicIsland.store — persistent key-value storage
        let store = JSValue(newObjectIn: context)!
        let storeGet: @convention(block) (String) -> JSValue = { [weak self] key in
            // Read from UserDefaults scoped to extension
            ...
        }
        let storeSet: @convention(block) (String, JSValue) -> Void = { [weak self] key, value in
            // Write to UserDefaults scoped to extension
            ...
        }
        store.setObject(storeGet, forKeyedSubscript: "get" as NSString)
        store.setObject(storeSet, forKeyedSubscript: "set" as NSString)
        di.setObject(store, forKeyedSubscript: "store" as NSString)

        // DynamicIsland.island — island control
        let island = JSValue(newObjectIn: context)!
        let activate: @convention(block) (Bool) -> Void = { [weak self] autoDismiss in
            guard let self else { return }
            DispatchQueue.main.async {
                AppState.shared.showHUD(module: .extension_(self.extensionID), autoDismiss: autoDismiss)
            }
        }
        let dismiss: @convention(block) () -> Void = {
            DispatchQueue.main.async { AppState.shared.dismiss() }
        }
        island.setObject(activate, forKeyedSubscript: "activate" as NSString)
        island.setObject(dismiss, forKeyedSubscript: "dismiss" as NSString)
        di.setObject(island, forKeyedSubscript: "island" as NSString)

        // DynamicIsland.notifications
        let notifications = JSValue(newObjectIn: context)!
        let notify: @convention(block) (JSValue) -> Void = { opts in
            let title = opts.forProperty("title")?.toString() ?? ""
            let body = opts.forProperty("body")?.toString() ?? ""
            // Send macOS notification scoped to this extension
            ...
        }
        notifications.setObject(notify, forKeyedSubscript: "send" as NSString)
        di.setObject(notifications, forKeyedSubscript: "notifications" as NSString)

        // DynamicIsland.http — sandboxed network (only if "network" permission granted)
        let http = JSValue(newObjectIn: context)!
        let fetch: @convention(block) (String, JSValue?) -> JSValue = { url, options in
            // Perform URLSession request, return Promise-like JSValue
            ...
        }
        http.setObject(fetch, forKeyedSubscript: "fetch" as NSString)
        di.setObject(http, forKeyedSubscript: "http" as NSString)

        // DynamicIsland.timers — setInterval/setTimeout
        let setInterval: @convention(block) (JSValue, Double) -> Int = { callback, ms in
            // Schedule repeating timer, return ID
            ...
        }
        let setTimeout: @convention(block) (JSValue, Double) -> Int = { callback, ms in
            // Schedule one-shot timer, return ID
            ...
        }
        let clearTimer: @convention(block) (Int) -> Void = { id in
            // Cancel timer by ID
            ...
        }
        context.setObject(setInterval, forKeyedSubscript: "setInterval" as NSString)
        context.setObject(setTimeout, forKeyedSubscript: "setTimeout" as NSString)
        context.setObject(clearTimer, forKeyedSubscript: "clearInterval" as NSString)
        context.setObject(clearTimer, forKeyedSubscript: "clearTimeout" as NSString)

        // console.log / console.error
        let console = JSValue(newObjectIn: context)!
        let log: @convention(block) (String) -> Void = { [weak self] msg in
            ExtensionLogger.shared.log(self?.extensionID ?? "", .info, msg)
        }
        let error: @convention(block) (String) -> Void = { [weak self] msg in
            ExtensionLogger.shared.log(self?.extensionID ?? "", .error, msg)
        }
        console.setObject(log, forKeyedSubscript: "log" as NSString)
        console.setObject(error, forKeyedSubscript: "error" as NSString)
        context.setObject(console, forKeyedSubscript: "console" as NSString)
    }

    /// Called by the host on each refresh cycle to get the current view tree.
    func fetchState() -> ExtensionViewState? {
        guard let callback = stateCallback else { return nil }
        let result = callback.call(withArguments: [])
        return parseViewState(result)
    }

    /// Called when user taps a button/toggle/slider in the extension's rendered UI.
    func handleAction(actionID: String, value: Any?) {
        actionCallback?.call(withArguments: [actionID, value as Any])
    }
}
```

#### 1.4 Extension JavaScript API (`DynamicIsland` global)

This is what extension developers use. The following is the **TypeScript type definition** shipped as `@dynamicisland/sdk`:

```typescript
// @dynamicisland/sdk — TypeScript definitions

declare namespace DynamicIsland {

  // ─── Module Registration ───────────────────────────────

  interface ModuleConfig {
    /** Render the compact view (188×34pt pill). Called on every refresh cycle. */
    compact: () => ViewNode;
    /**
     * Optional minimal rendering for the physical notch on notched Macs.
     * The host keeps the center hidden and only renders leading/trailing nodes.
     */
    minimalCompact?: {
      leading: () => ViewNode;
      trailing: () => ViewNode;
    };
    /** Render the expanded view (360×80pt drawer). */
    expanded: () => ViewNode;
    /** Render the full expanded view (400×200pt detail panel). */
    fullExpanded?: () => ViewNode;
    /** Called once when the extension is loaded. */
    onActivate?: () => void | Promise<void>;
    /** Called when the extension is being unloaded. */
    onDeactivate?: () => void | Promise<void>;
    /** Called when a user interacts with a button/toggle/slider. */
    onAction?: (actionID: string, value?: boolean | number | string) => void;
  }

  /** Register your extension module. Call this once in index.js. */
  function registerModule(config: ModuleConfig): void;

  // ─── Island Control ────────────────────────────────────

  namespace island {
    /** Request the island to show this extension (or Notifications when manifest.capabilities.notificationFeed=true). */
    function activate(autoDismiss?: boolean): void;
    /** Dismiss the island back to compact. */
    function dismiss(): void;
    /** Current island state: "compact" | "expanded" | "fullExpanded" */
    const state: "compact" | "expanded" | "fullExpanded";
    /** Whether this extension is currently the active module. */
    const isActive: boolean;
  }

  // ─── Persistent Storage ────────────────────────────────

  namespace store {
    /** Read a value from extension-scoped persistent storage. */
    function get(key: string): any;
    /** Write a value to extension-scoped persistent storage. */
    function set(key: string, value: any): void;
  }

  // ─── Notifications ─────────────────────────────────────

  namespace notifications {
    /** Send a macOS notification. Notification-feed extensions are mirrored to the shared notifications bar. */
    function send(options: {
      title: string;
      body: string;
      sound?: boolean;
      id?: string;
      appName?: string;
      bundleIdentifier?: string;
      senderName?: string;
      previewText?: string;
      avatarURL?: string;
      appIconURL?: string;
      systemNotification?: boolean;
    }): void;
  }

  // ─── HTTP (requires "network" permission) ──────────────

  namespace http {
    /** Fetch a URL. Returns parsed JSON or text. */
    function fetch(url: string, options?: {
      method?: "GET" | "POST" | "PUT" | "DELETE";
      headers?: Record<string, string>;
      body?: string;
    }): Promise<{
      status: number;
      data: any;
      text: string;
    }>;
  }

  // ─── Feedback ──────────────────────────────────────────

  /** Play haptic/audio feedback. */
  function playFeedback(type: "success" | "warning" | "error" | "selection"): void;

  /** Open a URL in the default browser. */
  function openURL(url: string): void;

  // ─── Settings ──────────────────────────────────────────

  namespace settings {
    /** Read a user-configured setting value. */
    function get(key: string): any;
    /** Write a setting value. */
    function set(key: string, value: any): void;
  }

  // ─── Local Usage (requires "usage" permission) ───────

  namespace system {
    /** Read locally available Codex and Claude usage summaries. */
    function getAIUsage(): {
      updatedAt: number;
      codex: {
        available: boolean;
        primary: null | {
          usedPercent: number;
          remainingPercent: number;
          windowMinutes: number;
          windowLabel: string;
          resetsAt: number | null;
        };
        secondary: null | {
          usedPercent: number;
          remainingPercent: number;
          windowMinutes: number;
          windowLabel: string;
          resetsAt: number | null;
        };
        planType: string | null;
        hasCredits: boolean;
        unlimited: boolean;
        source?: "local-summary" | "oauth-api" | "auth-token" | "unavailable";
      };
      claude: {
        available: boolean;
        status?: "allowed" | "allowed_warning" | "rejected";
        statusLabel?: string;
        hoursTillReset?: number | null;
        resetAt?: number | null;
        model?: string | null;
        updatedAt?: number;
        unifiedRateLimitFallbackAvailable?: boolean;
        isBlocked?: boolean;
        source?: "local-summary" | "oauth-api" | "stats-cache" | "unavailable";
      };
    } | null;

    /** Read latest mirrored notification entry (requires "notifications" permission). */
    function getLatestNotification(): {
      id: string;
      localID: string;
      appName: string;
      bundleIdentifier: string | null;
      appIcon: string;
      appIconURL: string | null;
      title: string;
      body: string;
      senderName: string | null;
      previewText: string | null;
      avatarURL: string | null;
      timestamp: number;
    } | null;

    /** Read mirrored notifications (requires "notifications" permission). */
    function getRecentNotifications(limit?: number): Array<{
      id: string;
      localID: string;
      appName: string;
      bundleIdentifier: string | null;
      appIcon: string;
      appIconURL: string | null;
      title: string;
      body: string;
      senderName: string | null;
      previewText: string | null;
      avatarURL: string | null;
      timestamp: number;
    }>;

    /**
     * Read WhatsApp Web bridge state (requires "network" permission).
     * Starts the bridge lazily on first call.
     */
    function getWhatsAppWeb(limit?: number): {
      state: "idle" | "loading" | "qrReady" | "loggedIn" | "error";
      statusText: string;
      loggedIn: boolean;
      qrCodeDataURL: string | null;
      lastError: string | null;
      messages: Array<{
        id: string;
        sender: string;
        preview: string;
        avatarURL: string | null;
        timestamp: number;
      }>;
    } | null;

    /** Start WhatsApp Web bridge (requires "network" permission). */
    function startWhatsAppWeb(): void;

    /** Force WhatsApp Web QR refresh (requires "network" permission). */
    function refreshWhatsAppWebQR(): void;

    /**
     * Queue a WhatsApp Web message send using the active logged-in session
     * (requires "network" permission).
     */
    function sendWhatsAppWebMessage(recipient: string, message: string): {
      ok: boolean;
      queued: boolean;
      error?: "permission_denied" | "main_thread_required" | "invalid_arguments" | "not_logged_in" | "bridge_not_ready";
    } | null;
  }
}

// ─── Timer Globals ─────────────────────────────────────
// Standard JS timer APIs are provided in the JSContext.
declare function setInterval(callback: () => void, ms: number): number;
declare function setTimeout(callback: () => void, ms: number): number;
declare function clearInterval(id: number): void;
declare function clearTimeout(id: number): void;

// ─── Console ───────────────────────────────────────────
declare namespace console {
  function log(...args: any[]): void;
  function error(...args: any[]): void;
  function warn(...args: any[]): void;
}
```

#### 1.5 View DSL (Declarative UI)

Extensions describe their UI using plain JavaScript objects. The host app converts these into native SwiftUI. No HTML, no DOM, no web views.

```typescript
// View node types — returned from compact(), expanded(), fullExpanded()

type ViewNode =
  // Layout
  | { type: "hstack"; spacing?: number; align?: "top" | "center" | "bottom"; distribution?: "natural" | "fillEqually"; children: ViewNode[] }
  | { type: "vstack"; spacing?: number; align?: "leading" | "center" | "trailing"; distribution?: "natural" | "fillEqually"; children: ViewNode[] }
  | { type: "zstack"; children: ViewNode[] }
  | { type: "spacer"; minLength?: number }

  // Content
  | { type: "text"; value: string; style?: TextStyle; color?: Color; lineLimit?: number }
  | { type: "icon"; name: string; size?: number; color?: Color }
  | { type: "image"; url: string; width: number; height: number; cornerRadius?: number }
  | { type: "progress"; value: number; total?: number; color?: Color }
  | { type: "circular-progress"; value: number; total?: number; lineWidth?: number; color?: Color }
  | { type: "gauge"; value: number; min?: number; max?: number; label?: string }
  | { type: "divider" }

  // Interactive
  | { type: "button"; label: ViewNode; action: string }
  | { type: "toggle"; isOn: boolean; label: string; action: string }
  | { type: "slider"; value: number; min: number; max: number; action: string }

  // Decorators
  | { type: "padding"; child: ViewNode; edges?: "all" | "horizontal" | "vertical"; amount?: number }
  | { type: "frame"; child: ViewNode; width?: number; height?: number; maxWidth?: number; maxHeight?: number }
  | { type: "opacity"; child: ViewNode; value: number }
  | { type: "background"; child: ViewNode; color: Color }
  | { type: "cornerRadius"; child: ViewNode; radius: number }
  | { type: "animation"; child: ViewNode; kind: "pulse" | "bounce" | "spin" | "blink" }

  // Conditional
  | { type: "if"; condition: boolean; then: ViewNode; else?: ViewNode }
  | null;

type TextStyle = "largeTitle" | "title" | "body" | "caption" | "footnote" | "monospaced" | "monospacedSmall";

type Color = "white" | "gray" | "red" | "green" | "blue" | "yellow"
  | "orange" | "purple" | "pink" | "teal" | "cyan"
  | { r: number; g: number; b: number; a?: number };
```

#### 1.6 View Helper Library (`View`)

The SDK ships a `View` helper so extension code reads cleanly. This is a thin wrapper that produces the JSON objects above:

```typescript
// Shipped as part of @dynamicisland/sdk — injected into JSContext as `View` global

const View = {
  // Layout
  hstack: (children: ViewNode[], opts?: { spacing?: number; align?: string; distribution?: "natural" | "fillEqually" }) =>
    ({ type: "hstack", spacing: opts?.spacing ?? 8, align: opts?.align, distribution: opts?.distribution, children }),
  vstack: (children: ViewNode[], opts?: { spacing?: number; align?: string; distribution?: "natural" | "fillEqually" }) =>
    ({ type: "vstack", spacing: opts?.spacing ?? 4, align: opts?.align, distribution: opts?.distribution, children }),
  zstack: (children: ViewNode[]) =>
    ({ type: "zstack", children }),
  spacer: (minLength?: number) =>
    ({ type: "spacer", minLength }),

  // Content
  text: (value: string, opts?: { style?: TextStyle; color?: Color; lineLimit?: number }) =>
    ({ type: "text", value, style: opts?.style ?? "body", color: opts?.color, lineLimit: opts?.lineLimit }),
  icon: (name: string, opts?: { size?: number; color?: Color }) =>
    ({ type: "icon", name, size: opts?.size ?? 14, color: opts?.color }),
  image: (url: string, opts: { width: number; height: number; cornerRadius?: number }) =>
    ({ type: "image", url, ...opts }),
  progress: (value: number, opts?: { total?: number; color?: Color }) =>
    ({ type: "progress", value, total: opts?.total ?? 1, color: opts?.color }),
  circularProgress: (value: number, opts?: { total?: number; lineWidth?: number; color?: Color }) =>
    ({ type: "circular-progress", value, total: opts?.total ?? 1, lineWidth: opts?.lineWidth ?? 3, color: opts?.color }),
  gauge: (value: number, opts?: { min?: number; max?: number; label?: string }) =>
    ({ type: "gauge", value, ...opts }),
  divider: () =>
    ({ type: "divider" }),

  // Interactive
  button: (label: ViewNode, action: string) =>
    ({ type: "button", label, action }),
  toggle: (isOn: boolean, label: string, action: string) =>
    ({ type: "toggle", isOn, label, action }),
  slider: (value: number, min: number, max: number, action: string) =>
    ({ type: "slider", value, min, max, action }),

  // Decorators
  padding: (child: ViewNode, opts?: { edges?: string; amount?: number }) =>
    ({ type: "padding", child, edges: opts?.edges ?? "all", amount: opts?.amount ?? 8 }),
  frame: (child: ViewNode, opts: { width?: number; height?: number; maxWidth?: number; maxHeight?: number }) =>
    ({ type: "frame", child, ...opts }),
  opacity: (child: ViewNode, value: number) =>
    ({ type: "opacity", child, value }),
  background: (child: ViewNode, color: Color) =>
    ({ type: "background", child, color }),
  cornerRadius: (child: ViewNode, radius: number) =>
    ({ type: "cornerRadius", child, radius }),
  animate: (child: ViewNode, kind: string) =>
    ({ type: "animation", child, kind }),

  // Conditional
  when: (condition: boolean, then: ViewNode, otherwise?: ViewNode) =>
    condition ? then : (otherwise ?? null),

  // Convenience
  timerText: (seconds: number, opts?: { style?: TextStyle }) => {
    const m = Math.floor(seconds / 60);
    const s = seconds % 60;
    return { type: "text", value: `${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`, style: opts?.style ?? "monospaced" };
  },
};
```

`distribution` controls how direct stack children consume space:
- `"natural"`: children use intrinsic size
- `"fillEqually"`: children share equal space along the stack axis

The `View` global is pre-injected into every extension's JSContext so no imports are needed.

---

### Phase 2: Extension Host & Sandbox

#### 2.1 JSContext Sandbox

Each extension gets its own `JSContext` (JavaScriptCore). This provides:

- **Memory isolation** — each context has its own heap
- **No filesystem access** — no `fs`, `require`, `import` (only the injected globals)
- **No DOM** — no `document`, `window`, `XMLHttpRequest`
- **No eval** — `eval()` and `Function()` constructor are disabled
- **Controlled network** — only `DynamicIsland.http.fetch()` (proxied through Swift `URLSession`)
- **Rate limiting** — max 10 activations/minute, max 60 HTTP requests/minute per extension

```swift
/// Swift-side sandbox enforcement
final class ExtensionSandbox {
    static func configureContext(_ context: JSContext, permissions: [String]) {
        // Remove dangerous globals
        context.evaluateScript("delete globalThis.eval")
        context.evaluateScript("delete globalThis.Function")

        // Only inject DynamicIsland.http if "network" permission granted
        if !permissions.contains("network") {
            // DynamicIsland.http.fetch will throw "Permission denied"
        }

        // Memory limit: 50MB per extension
        // JSContext doesn't have built-in memory limits, so we monitor via:
        // - JSContext.virtualMachine.addManagedReference (track allocations)
        // - Periodic heap size checks
        // - Kill context if exceeded

        // CPU: if a script takes >5s to evaluate, terminate it
        context.exceptionHandler = { ctx, exception in
            ExtensionLogger.shared.log(extensionID, .error, exception?.toString() ?? "Unknown error")
        }
    }
}
```

#### 2.2 Extension Lifecycle Manager

```swift
/// Manages all loaded extension runtimes.
final class ExtensionManager: ObservableObject {
    static let shared = ExtensionManager()

    /// All installed extensions (discovered from disk).
    @Published var installed: [ExtensionManifest] = []

    /// Currently running extension runtimes.
    @Published var runtimes: [String: ExtensionJSRuntime] = [:]

    /// Extension states (view trees), refreshed on timer.
    @Published var extensionStates: [String: ExtensionViewState] = [:]

    /// Directory where extensions are installed.
    /// ~/Library/Application Support/DynamicIsland/Extensions/
    let extensionsDirectory: URL

    /// Discover all installed extensions from disk.
    func discoverExtensions() {
        // Scan extensionsDirectory for directories containing manifest.json
        // Parse and validate each manifest
        // Populate `installed`
    }

    /// Load and activate an extension.
    func activate(extensionID: String) {
        guard let manifest = installed.first(where: { $0.id == extensionID }) else { return }
        let runtime = ExtensionJSRuntime(extensionID: extensionID, bundle: manifest.bundleURL)
        runtimes[extensionID] = runtime

        // Start refresh timer based on manifest.refreshInterval
        startRefreshTimer(for: extensionID, interval: manifest.refreshInterval)
    }

    /// Deactivate an extension.
    func deactivate(extensionID: String) {
        runtimes[extensionID]?.cleanup()
        runtimes.removeValue(forKey: extensionID)
        extensionStates.removeValue(forKey: extensionID)
    }

    /// Called on refresh timer: get the latest view state from the extension.
    func refreshState(extensionID: String) {
        guard let runtime = runtimes[extensionID] else { return }
        if let state = runtime.fetchState() {
            DispatchQueue.main.async {
                self.extensionStates[extensionID] = state
            }
        }
    }

    /// Forward user action to the extension.
    func handleAction(extensionID: String, actionID: String, value: Any? = nil) {
        runtimes[extensionID]?.handleAction(actionID: actionID, value: value)
        // Re-fetch state after action
        refreshState(extensionID: extensionID)
    }

    /// Install from a .zip or directory.
    func install(from source: URL) throws -> ExtensionManifest { ... }

    /// Uninstall an extension.
    func uninstall(extensionID: String) throws { ... }
}
```

#### 2.3 View State (JSON ↔ Swift)

The extension's `compact()`, `expanded()`, `fullExpanded()` return JSON objects. The Swift side parses them:

```swift
/// Parsed view state from an extension's JS render functions.
struct ExtensionViewState {
    var compact: ViewNode
    var expanded: ViewNode
    var fullExpanded: ViewNode?
    var minimalLeading: ViewNode?
    var minimalTrailing: ViewNode?
}

enum StackDistribution: String, Codable {
    case natural
    case fillEqually
}

/// A node in the extension's view tree (parsed from JS objects).
indirect enum ViewNode: Codable {
    // Layout
    case hstack(spacing: CGFloat, alignment: VerticalAlignment, distribution: StackDistribution, children: [ViewNode])
    case vstack(spacing: CGFloat, alignment: HorizontalAlignment, distribution: StackDistribution, children: [ViewNode])
    case zstack(children: [ViewNode])
    case spacer(minLength: CGFloat?)

    // Content
    case text(String, style: TextStyle, color: ColorValue)
    case icon(name: String, size: CGFloat, color: ColorValue)
    case image(url: String, width: CGFloat, height: CGFloat, cornerRadius: CGFloat)
    case progress(value: Double, total: Double, color: ColorValue)
    case circularProgress(value: Double, total: Double, lineWidth: CGFloat, color: ColorValue)
    case gauge(value: Double, min: Double, max: Double, label: String?)
    case divider

    // Interactive
    case button(label: ViewNode, actionID: String)
    case toggle(isOn: Bool, label: String, actionID: String)
    case slider(value: Double, min: Double, max: Double, actionID: String)

    // Decorators
    case padding(ViewNode, edges: Edge.Set, amount: CGFloat)
    case frame(ViewNode, width: CGFloat?, height: CGFloat?, maxWidth: CGFloat?, maxHeight: CGFloat?)
    case opacity(ViewNode, Double)
    case background(ViewNode, ColorValue)
    case cornerRadius(ViewNode, CGFloat)
    case animation(ViewNode, AnimationType)

    // Conditional / empty
    case empty

    /// Parse from a JSValue (returned by extension's render function).
    static func from(_ jsValue: JSValue) -> ViewNode? {
        guard let type = jsValue.forProperty("type")?.toString() else { return nil }
        switch type {
        case "hstack":
            let children = parseChildren(jsValue.forProperty("children"))
            let spacing = jsValue.forProperty("spacing")?.toDouble() ?? 8
            let distribution = StackDistribution(rawValue: jsValue.forProperty("distribution")?.toString() ?? "natural") ?? .natural
            return .hstack(spacing: spacing, alignment: .center, distribution: distribution, children: children)
        case "text":
            let value = jsValue.forProperty("value")?.toString() ?? ""
            let style = TextStyle(rawValue: jsValue.forProperty("style")?.toString() ?? "body") ?? .body
            return .text(value, style: style, color: parseColor(jsValue.forProperty("color")))
        case "button":
            let label = ViewNode.from(jsValue.forProperty("label")) ?? .empty
            let actionID = jsValue.forProperty("action")?.toString() ?? ""
            return .button(label: label, actionID: actionID)
        // ... all other cases
        default:
            return nil
        }
    }
}
```

---

### Phase 3: Extension ↔ Module Integration

#### 3.1 Dynamic Module Registration

Currently, modules are a hardcoded `ModuleType` enum. For extensions, add dynamic routing:

```swift
/// Extends the active module concept to support extensions.
enum ActiveModule: Equatable, Hashable {
    case builtIn(ModuleType)
    case extension_(String)  // Extension ID

    var displayName: String {
        switch self {
        case .builtIn(let type): return type.displayName
        case .extension_(let id):
            return ExtensionManager.shared.installed.first { $0.id == id }?.name ?? id
        }
    }

    var iconName: String {
        switch self {
        case .builtIn(let type): return type.iconName
        case .extension_(let id):
            return ExtensionManager.shared.installed.first { $0.id == id }?.iconName ?? "puzzlepiece.extension"
        }
    }
}
```

Update `AppState`:
```swift
@Published var activeModule: ActiveModule? = nil

func cycleModule(forward: Bool) {
    // Combine built-in enabled modules + active extension modules
    let allModules: [ActiveModule] =
        ModuleType.allCases.filter { isModuleEnabled($0) }.map { .builtIn($0) }
        + ExtensionManager.shared.runtimes.keys.map { .extension_($0) }
    // ... cycle through
}
```

On notched Macs, compact mode should also support a hardware-notch variant:
- If the active module supports `minimalCompact`, expand the compact width symmetrically into the menu bar only when there is safe room on both sides.
- Render `minimalLeading` on the left and `minimalTrailing` on the right.
- If the module does not support `minimalCompact`, keep the compact notch as a pure black hardware-shaped notch with no hints.

#### 3.2 View Routing Update

```swift
// In CompactView, ExpandedView, FullExpandedView:
switch appState.activeModule {
case .builtIn(let type):
    // Existing switch on ModuleType
case .extension_(let extensionID):
    ExtensionRendererView(extensionID: extensionID, displayMode: .compact)
case nil:
    // Default idle view
}
```

#### 3.3 Extension Renderer (SwiftUI)

```swift
/// Renders an extension's ViewNode tree into native SwiftUI.
struct ExtensionRendererView: View {
    let extensionID: String
    let displayMode: DisplayMode // .compact, .expanded, .fullExpanded, .minimalLeading, .minimalTrailing

    @ObservedObject var manager = ExtensionManager.shared

    var body: some View {
        if let state = manager.extensionStates[extensionID] {
            let node = switch displayMode {
            case .compact: state.compact
            case .expanded: state.expanded
            case .fullExpanded: state.fullExpanded ?? state.expanded
            case .minimalLeading: state.minimalLeading ?? .empty
            case .minimalTrailing: state.minimalTrailing ?? .empty
            }
            ViewNodeRenderer(node: node, extensionID: extensionID)
        } else {
            ProgressView()
                .scaleEffect(0.5)
        }
    }
}

/// Recursively renders ViewNode tree into SwiftUI views.
struct ViewNodeRenderer: View {
    let node: ViewNode
    let extensionID: String

    var body: some View {
        switch node {
        case .text(let string, let style, let color):
            Text(string)
                .font(style.font)
                .foregroundColor(color.swiftUI)

        case .icon(let name, let size, let color):
            Image(systemName: name)
                .font(.system(size: size))
                .foregroundColor(color.swiftUI)

        case .hstack(let spacing, let alignment, let distribution, let children):
            HStack(alignment: alignment, spacing: spacing) {
                ForEach(children.indices, id: \.self) { i in
                    if distribution == .fillEqually {
                        ViewNodeRenderer(node: children[i], extensionID: extensionID)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ViewNodeRenderer(node: children[i], extensionID: extensionID)
                    }
                }
            }

        case .vstack(let spacing, let alignment, let distribution, let children):
            VStack(alignment: alignment, spacing: spacing) {
                ForEach(children.indices, id: \.self) { i in
                    if distribution == .fillEqually {
                        ViewNodeRenderer(node: children[i], extensionID: extensionID)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ViewNodeRenderer(node: children[i], extensionID: extensionID)
                    }
                }
            }

        case .button(let label, let actionID):
            Button {
                ExtensionManager.shared.handleAction(
                    extensionID: extensionID,
                    actionID: actionID
                )
            } label: {
                ViewNodeRenderer(node: label, extensionID: extensionID)
            }
            .buttonStyle(.plain)

        case .progress(let value, let total, let color):
            ProgressView(value: value, total: total)
                .tint(color.swiftUI)

        case .spacer(let minLength):
            Spacer(minLength: minLength)

        case .divider:
            Divider()

        case .empty:
            EmptyView()

        // ... all other cases follow the same pattern
        }
    }
}
```

---

### Phase 4: Extension Store

#### 4.1 Store Backend

- **Registry**: GitHub-hosted `registry.json` (like Homebrew taps or Raycast's store)
- **Hosting**: Extension zips on GitHub Releases or CDN
- **Submission**: PR to the registry repo with automated validation
- **Review**: CI checks manifest, permissions, bundle size + manual review for dangerous permissions

```json
// registry.json — hosted at https://extensions.dynamicisland.app/registry.json
{
  "version": 1,
  "extensions": [
    {
      "id": "com.developer.pomodoro",
      "name": "Pomodoro Timer",
      "author": "Jane Developer",
      "description": "Focus timer with Pomodoro technique",
      "version": "1.2.0",
      "minAppVersion": "1.0.0",
      "categories": ["productivity", "timer"],
      "permissions": ["notifications", "storage"],
      "downloadURL": "https://github.com/jane/pomodoro-island/releases/download/v1.2.0/pomodoro.zip",
      "iconURL": "https://raw.githubusercontent.com/jane/pomodoro-island/main/assets/icon.png",
      "downloads": 1523,
      "rating": 4.8,
      "size": 45000,
      "checksum": "sha256:abc123...",
      "screenshots": [
        "https://raw.githubusercontent.com/jane/pomodoro-island/main/screenshots/compact.png",
        "https://raw.githubusercontent.com/jane/pomodoro-island/main/screenshots/expanded.png"
      ],
      "updatedAt": "2025-03-01T00:00:00Z"
    }
  ]
}
```

#### 4.2 Store UI (in Settings)

Add a new tab to Settings:

```
Settings TabView:
├── General
├── Modules
├── Appearance
├── Extensions        ← NEW
│   ├── Installed     (list with enable/disable/uninstall)
│   ├── Browse        (search + category grid from registry)
│   └── Developer     (load from path, debug console, hot-reload)
└── Advanced
```

**Browse**: Search bar, category pills, extension cards with install button
**Installed**: Toggle enable/disable, version info, update button, extension settings
**Developer**: Load from path, hot-reload toggle, live console log viewer

#### 4.3 Store Client

```swift
final class ExtensionStoreClient: ObservableObject {
    @Published var catalog: [ExtensionListing] = []
    @Published var isLoading = false

    func fetchCatalog() async { ... }
    func install(_ listing: ExtensionListing) async throws { ... }
    func checkUpdates() async -> [ExtensionUpdate] { ... }
    func search(query: String, category: String?) -> [ExtensionListing] { ... }
}
```

---

### Phase 5: Developer Tools & CLI

#### 5.1 CLI Tool (`npx @dynamicisland/cli`)

```bash
# Create a new extension from template
npx @dynamicisland/cli create "Pomodoro Timer" --id com.me.pomodoro

# Start dev mode (watches for changes, hot-reloads into running app)
npx @dynamicisland/cli dev

# Build (compile TS → JS, validate manifest, package .zip)
npx @dynamicisland/cli build

# Publish to the extension registry
npx @dynamicisland/cli publish
```

#### 5.2 Scaffolded Project

```
pomodoro/
├── package.json
├── tsconfig.json
├── manifest.json
├── src/
│   └── index.ts          # Extension source (TypeScript)
├── dist/
│   └── index.js          # Compiled output (JS)
├── assets/
│   ├── icon.png
│   └── screenshots/
├── settings.json
└── README.md
```

`package.json`:
```json
{
  "name": "pomodoro-island",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "dev": "dynamicisland dev",
    "build": "dynamicisland build",
    "publish": "dynamicisland publish"
  },
  "devDependencies": {
    "@dynamicisland/sdk": "^1.0.0",
    "@dynamicisland/cli": "^1.0.0",
    "typescript": "^5.0.0"
  }
}
```

#### 5.3 Hot-Reload Protocol

The CLI communicates with the running DynamicIsland app via a local Unix socket or Bonjour:

1. CLI watches `src/` for changes
2. On change: compile TS → JS
3. Send reload message to app: `{ "command": "reload", "extensionID": "com.me.pomodoro", "bundlePath": "/path/to/dist" }`
4. App tears down the old JSContext, creates a new one with the updated JS
5. Extension state refreshes immediately

```swift
/// Listens for dev tool reload commands on a Unix socket.
final class ExtensionDevServer {
    private var server: NWListener?
    let socketPath = "/tmp/dynamicisland-dev.sock"

    func start() {
        // Listen on Unix domain socket
        // On "reload" command: ExtensionManager.shared.deactivate(id); activate(id)
        // On "logs" command: stream ExtensionLogger output back to CLI
    }
}
```

---

### Phase 6: Settings Schema Renderer

Extensions define their settings in `settings.json`. The host renders them as native SwiftUI forms:

```json
// settings.json
{
  "sections": [
    {
      "title": "Timer",
      "fields": [
        { "type": "slider", "key": "workDuration", "label": "Work duration (min)", "min": 5, "max": 60, "step": 5, "default": 25 },
        { "type": "slider", "key": "breakDuration", "label": "Break duration (min)", "min": 1, "max": 15, "step": 1, "default": 5 },
        { "type": "stepper", "key": "sessionsBeforeLongBreak", "label": "Sessions before long break", "min": 2, "max": 8, "default": 4 }
      ]
    },
    {
      "title": "Notifications",
      "fields": [
        { "type": "toggle", "key": "notifyOnComplete", "label": "Notify when timer ends", "default": true },
        { "type": "toggle", "key": "playSound", "label": "Play sound", "default": true },
        { "type": "picker", "key": "soundName", "label": "Sound", "options": [
          { "value": "bell", "label": "Bell" },
          { "value": "chime", "label": "Chime" },
          { "value": "gong", "label": "Gong" }
        ], "default": "bell" }
      ]
    }
  ]
}
```

Supported field types: `toggle`, `text`, `slider`, `stepper`, `picker`, `color`

```swift
/// Renders a settings.json schema into a SwiftUI Form.
struct ExtensionSettingsRenderer: View {
    let extensionID: String
    let schema: SettingsSchema

    var body: some View {
        Form {
            ForEach(schema.sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.fields, id: \.key) { field in
                        renderField(field)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func renderField(_ field: SettingsField) -> some View {
        switch field.type {
        case "toggle":
            Toggle(field.label, isOn: binding(for: field.key, default: field.defaultBool))
        case "slider":
            VStack(alignment: .leading) {
                Text(field.label)
                Slider(value: binding(for: field.key, default: field.defaultDouble),
                       in: field.min...field.max, step: field.step)
            }
        case "picker":
            Picker(field.label, selection: binding(for: field.key, default: field.defaultString)) {
                ForEach(field.options, id: \.value) { opt in
                    Text(opt.label).tag(opt.value)
                }
            }
        // ... text, stepper, color
        }
    }
}
```

---

### Phase 7: Security & Permissions

#### 7.1 Permission Model

```typescript
// Permissions declared in manifest.json
type Permission =
  | "notifications"      // Can send macOS notifications
  | "storage"            // Can persist data across sessions
  | "network"            // Can make HTTP requests
  | "clipboard"          // Can read/write clipboard
  | "systemInfo"         // Can read CPU, memory, disk info
  | "location"           // Can access location
  | "calendar"           // Can read calendar events
  | "shellCommand";      // Can execute shell commands (DANGEROUS)
```

#### 7.2 Runtime Enforcement

- `JSContext` has no filesystem access by default — all storage goes through `DynamicIsland.store`
- Network requests are proxied through Swift's `URLSession` — can be logged, rate-limited, or blocked
- `shellCommand` requires explicit user approval per command via a system dialog
- Extensions that throw >10 uncaught errors in 1 minute are auto-disabled
- Extensions that exceed 50MB memory are terminated
- CPU: script execution timeouts (5s for sync, 30s for async operations)

#### 7.3 Validation on Install

1. Parse and validate `manifest.json` against JSON Schema
2. Verify `index.js` exists and is valid JavaScript (attempt parse)
3. Check `minAppVersion` compatibility
4. Warn user about dangerous permissions (`network`, `clipboard`, `shellCommand`)
5. Verify checksum if installing from store
6. Bundle size limit: 5MB (JS is much smaller than Swift bundles)

---

### Phase 8: Example Extension — Pomodoro Timer

Complete working extension in JavaScript:

```javascript
// index.js — Pomodoro Timer Extension

let remaining = 25 * 60;
let totalDuration = 25 * 60;
let isRunning = false;
let isBreak = false;
let sessionsCompleted = 0;
let timerID = null;

function formatTime(secs) {
  const m = Math.floor(secs / 60);
  const s = secs % 60;
  return `${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
}

function tick() {
  if (!isRunning) return;
  remaining--;
  if (remaining <= 0) {
    timerCompleted();
  }
}

function timerCompleted() {
  isRunning = false;
  clearInterval(timerID);
  timerID = null;

  if (!isBreak) {
    sessionsCompleted++;
    DynamicIsland.store.set("sessionsCompleted", sessionsCompleted);
  }

  isBreak = !isBreak;
  const breakDuration = (DynamicIsland.settings.get("breakDuration") || 5) * 60;
  const workDuration = (DynamicIsland.settings.get("workDuration") || 25) * 60;
  totalDuration = isBreak ? breakDuration : workDuration;
  remaining = totalDuration;

  if (DynamicIsland.settings.get("notifyOnComplete") !== false) {
    DynamicIsland.notifications.send({
      title: isBreak ? "Time for a break!" : "Break's over!",
      body: isBreak ? `You've completed ${sessionsCompleted} sessions` : "Let's focus!",
      sound: DynamicIsland.settings.get("playSound") !== false,
    });
  }

  DynamicIsland.playFeedback("success");
}

DynamicIsland.registerModule({
  onActivate() {
    sessionsCompleted = DynamicIsland.store.get("sessionsCompleted") || 0;
    totalDuration = (DynamicIsland.settings.get("workDuration") || 25) * 60;
    remaining = totalDuration;
  },

  onDeactivate() {
    if (timerID) clearInterval(timerID);
    DynamicIsland.store.set("sessionsCompleted", sessionsCompleted);
  },

  onAction(actionID, value) {
    switch (actionID) {
      case "toggleTimer":
        isRunning = !isRunning;
        if (isRunning) {
          timerID = setInterval(tick, 1000);
          DynamicIsland.island.activate(false);
        } else {
          clearInterval(timerID);
          timerID = null;
        }
        break;
      case "reset":
        isRunning = false;
        clearInterval(timerID);
        timerID = null;
        remaining = totalDuration;
        break;
      case "skip":
        timerCompleted();
        break;
    }
  },

  compact() {
    const progress = 1 - remaining / totalDuration;
    const statusIcon = isBreak ? "cup.and.saucer.fill" : "brain.head.profile";
    const statusColor = isBreak ? "green" : remaining < 60 ? "red" : "white";

    return View.hstack([
      View.icon(statusIcon, { size: 12, color: statusColor }),
      View.timerText(remaining),
      isRunning
        ? View.circularProgress(progress, { lineWidth: 2, color: statusColor })
        : null,
    ], { spacing: 6 });
  },

  minimalCompact: {
    leading() {
      const progress = 1 - remaining / totalDuration;
      const statusColor = isBreak ? "green" : remaining < 60 ? "red" : "white";
      return View.circularProgress(progress, { lineWidth: 3, color: statusColor });
    },

    trailing() {
      return View.button(
        View.icon(isRunning ? "pause.fill" : "play.fill", { size: 11 }),
        "toggleTimer"
      );
    }
  },

  expanded() {
    const progress = 1 - remaining / totalDuration;
    const statusColor = isBreak ? "green" : remaining < 60 ? "red" : "white";

    return View.hstack([
      View.circularProgress(progress, { lineWidth: 4, color: statusColor }),
      View.vstack([
        View.text(isBreak ? "Break Time" : "Focus Session", { style: "title" }),
        View.timerText(remaining),
        View.text(`${sessionsCompleted} sessions today`, { style: "footnote" }),
      ], { spacing: 4 }),
      View.spacer(),
      View.button(
        View.icon(isRunning ? "pause.fill" : "play.fill", { size: 18 }),
        "toggleTimer"
      ),
    ], { spacing: 12 });
  },

  fullExpanded() {
    const progress = 1 - remaining / totalDuration;
    const statusColor = isBreak ? "green" : remaining < 60 ? "red" : "white";

    return View.vstack([
      View.hstack([
        View.circularProgress(progress, { lineWidth: 6, color: statusColor }),
        View.vstack([
          View.text(isBreak ? "Break" : "Focus", { style: "largeTitle" }),
          View.timerText(remaining),
        ], { spacing: 4 }),
        View.spacer(),
      ]),
      View.progress(progress, { color: statusColor }),
      View.hstack([
        View.button(View.icon("arrow.counterclockwise", { size: 18 }), "reset"),
        View.button(
          View.icon(isRunning ? "pause.circle.fill" : "play.circle.fill", { size: 36 }),
          "toggleTimer"
        ),
        View.button(View.icon("forward.fill", { size: 18 }), "skip"),
      ], { spacing: 24 }),
      View.divider(),
      View.hstack([
        View.text("Sessions today", { style: "caption" }),
        View.spacer(),
        View.text(`${sessionsCompleted}`, { style: "monospaced" }),
      ]),
    ], { spacing: 12 });
  },
});
```

---

## Implementation Order

1. **ViewNode types & renderer** — Define `ViewNode` enum in Swift, build `ViewNodeRenderer` SwiftUI view
2. **JSContext bridge** — Create `ExtensionJSRuntime` with injected `DynamicIsland` global, `View` helpers, timers, console
3. **Extension lifecycle** — `ExtensionManager` to discover, load, activate, deactivate extensions
4. **Dynamic module routing** — `ActiveModule` enum, update `CompactView`/`ExpandedView`/`FullExpandedView` routing
5. **Storage & settings** — `DynamicIsland.store`, `DynamicIsland.settings`, settings schema renderer
6. **Sandbox & permissions** — Lock down JSContext, enforce permission model
7. **Store client** — Fetch registry, download, install, update extensions
8. **Store UI** — Browse, Installed, Developer tabs in Settings
9. **CLI tool** — `@dynamicisland/cli` for create, dev, build, publish
10. **Hot-reload** — Unix socket dev server, file watcher, live reload
11. **Pomodoro reference extension** — Prove the SDK works end-to-end

---

## Architecture Summary

```
┌─────────────────────────────────────────────┐
│              DynamicIsland App              │
│                                             │
│  ┌─────────┐  ┌──────────┐  ┌───────────┐  │
│  │ AppState│  │ Built-in │  │ Extension │  │
│  │         │  │ Modules  │  │ Manager   │  │
│  └────┬────┘  └────┬─────┘  └─────┬─────┘  │
│       │            │              │         │
│  ┌────▼────────────▼──────────────▼──────┐  │
│  │         IslandContainerView           │  │
│  │  ┌──────────┐  ┌──────────────────┐   │  │
│  │  │ Built-in │  │ ExtensionRenderer│   │  │
│  │  │ Views    │  │  (ViewNode→SwiftUI)  │  │
│  │  └──────────┘  └────────▲─────────┘   │  │
│  └─────────────────────────┼─────────────┘  │
│                            │                │
│  ┌─────────────────────────┼─────────────┐  │
│  │       JSContext (per extension)        │  │
│  │                                       │  │
│  │  ┌──────────────┐  ┌──────────────┐   │  │
│  │  │ DynamicIsland│  │   View.*     │   │  │
│  │  │ (global API) │  │  (helpers)   │   │  │
│  │  └──────────────┘  └──────────────┘   │  │
│  │                                       │  │
│  │  ┌──────────────────────────────────┐ │  │
│  │  │    extension's index.js          │ │  │
│  │  │    (user code runs here)         │ │  │
│  │  └──────────────────────────────────┘ │  │
│  └───────────────────────────────────────┘  │
└─────────────────────────────────────────────┘
```

## Why JavaScript (not Swift)

| Aspect | Swift extensions | JavaScript extensions |
|--------|-----------------|----------------------|
| Developer pool | Small (macOS devs only) | Massive (any web dev) |
| Tooling required | Xcode + Apple Developer account | Any text editor + Node.js |
| Sandbox | Complex (XPC services) | Simple (JavaScriptCore is sandboxed by default) |
| Hot reload | Recompile + restart | Instant (re-evaluate JS) |
| Bundle size | ~1-10MB (compiled binary) | ~1-50KB (plain JS) |
| Distribution | Signed .framework bundles | Plain .zip with JS + manifest |
| Security | Must trust compiled code | Can inspect source, JSContext is isolated |
| Performance | Native speed | Slightly slower, but UI is just JSON → SwiftUI |
| Cross-platform | macOS only | Portable if we ever expand |
| Runtime | macOS built-in (no deps) | JavaScriptCore (macOS built-in, no deps) |

---

## Constraints

- macOS 14 Sonoma minimum
- JavaScriptCore only (built into macOS — no V8, no Node.js, no Electron, no web views)
- Extensions cannot inject arbitrary SwiftUI — only the ViewNode JSON DSL
- Extensions cannot steal focus (island is `.nonactivatingPanel`)
- Memory limit: 50MB per extension, 200MB total
- Bundle size limit: 5MB per extension
- Extension refresh rate: minimum 100ms, default 1s
- Registry refresh: every 6 hours (cached locally)
- ViewNode DSL is forward-compatible — new node types can be added without breaking old extensions
- Built-in modules may eventually be refactored to use the same extension architecture

---

## Non-Goals (for v1)

- Cross-platform (iOS/iPadOS) — macOS only for now
- React/JSX syntax — plain JS objects for now (could add JSX transform in v2)
- Extension-to-extension communication
- Custom window/popover support (extensions only render inside the island)
- App Store distribution (use our own store)
- Paid extensions or monetization (all free for v1)
- Node.js APIs (`fs`, `path`, `crypto`, etc.) — only the injected DynamicIsland globals
