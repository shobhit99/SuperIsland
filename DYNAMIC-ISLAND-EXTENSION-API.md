# DPI: DynamicIsland Plugin Interface (Builder Guide)

This guide documents the **currently exposed extension APIs** in DynamicIsland so builders can ship working extensions quickly.

Use this as your source of truth for what works in the runtime today.

## 1. Quick Start

1. Create a folder under `Extensions/`, for example `Extensions/my-timer/`.
2. Add a `manifest.json`.
3. Add an `index.js` that calls `DynamicIsland.registerModule(...)` once.
4. Optional: add `settings.json` for native settings UI.
5. Launch the app, open **Settings -> Extensions**, then activate your extension.

Minimal example:

```js
DynamicIsland.registerModule({
  compact() {
    return View.hstack([
      View.icon("bolt.fill", { color: "yellow" }),
      View.text("Hello", { style: "body" })
    ]);
  },
  expanded() {
    return View.text("Expanded view", { style: "title" });
  },
  onAction(actionID, value) {
    console.log("Action:", actionID, value);
  }
});
```

## 2. Extension Package Layout

```text
my-extension/
  manifest.json
  index.js
  settings.json         (optional)
  assets/               (optional)
```

## 3. `manifest.json` Reference

Required fields:

- `id` (string): globally unique ID (`com.you.extension`).
- `name` (string)
- `version` (string)

Common fields:

- `main` (string, default: `index.js`)
- `minAppVersion` (string, default: `1.0.0`)
- `description` (string, default: `""`)
- `author` (`{ name, url? }`)
- `icon` (string path)
- `license` (string)
- `categories` (string[])
- `permissions` (string[])
- `capabilities`:
  - `compact` (default `true`)
  - `expanded` (default `true`)
  - `fullExpanded` (default `true`)
  - `minimalCompact` (default `false`)
  - `backgroundRefresh` (default `true`)
  - `settings` (default `true`)
  - `notificationFeed` (default `false`) - extension is hidden from module slots; `DynamicIsland.island.activate()` opens the shared Notifications module
- `refreshInterval` (seconds, default `1.0`, minimum `0.1`)
- `activationTriggers` (default `["manual"]`)

Example:

```json
{
  "id": "com.workview.pomodoro",
  "name": "Pomodoro Timer",
  "version": "1.0.0",
  "main": "index.js",
  "permissions": ["notifications", "storage"],
  "refreshInterval": 1.0
}
```

## 4. Runtime Lifecycle

Your extension registers exactly one module:

```js
DynamicIsland.registerModule({
  compact,                   // required
  expanded,                  // recommended
  fullExpanded,              // optional
  minimalCompact,            // optional
  onActivate,                // optional
  onDeactivate,              // optional
  onAction                   // optional
});
```

### Lifecycle callbacks

- `onActivate()` runs when runtime is activated.
- `onDeactivate()` runs before runtime teardown.
- `onAction(actionID, value?)` runs for UI interactions.

### Render callbacks

- `compact()` -> rendered in compact island.
- `expanded()` -> rendered in expanded island.
- `fullExpanded()` -> rendered in full panel; if missing, expanded is reused.
- `minimalCompact.leading()/trailing()` -> rendered on notched compact variant when available.

## 5. `DynamicIsland` Global API

### `DynamicIsland.registerModule(config)`

Registers your extension module config.

### `DynamicIsland.island`

- `activate(autoDismiss = true)`
- `dismiss()`
- `state`: `"compact" | "expanded" | "fullExpanded"`
- `isActive`: boolean

Notes:

- If `manifest.capabilities.notificationFeed` is `true`, `activate()` targets the main Notifications module instead of an extension-specific island slot.

Timer/background-safe pattern:

```js
function revealIsland() {
  DynamicIsland.island.activate(false);
  // Optional second activation to survive host/menu transition races.
  setTimeout(() => DynamicIsland.island.activate(false), 120);
}
```

### `DynamicIsland.store`

Persistent extension-scoped key/value storage.

- `get(key)` -> value or `null`
- `set(key, value)`

Notes:

- `null` clears/removes the key.
- Scalars and JSON-compatible objects/arrays are supported.

### `DynamicIsland.settings`

Extension settings key/value store (paired with `settings.json`).

- `get(key)` -> value or `null`
- `set(key, value)`

### `DynamicIsland.notifications`

- `send(options)`
  - `title` (string)
  - `body` (string)
  - `sound?` (boolean)
  - `id?` (string): stable ID for de-dup/update in notification feed
  - `appName?` (string): app label shown in notification bar
  - `bundleIdentifier?` (string): app bundle ID used for app icon fallback
  - `senderName?` (string): sender/contact name shown as headline
  - `previewText?` (string): message/content preview
  - `avatarURL?` (string): sender avatar (`file://`, absolute file path, `http(s)://`)
  - `appIconURL?` (string): extension/app icon (`file://`, absolute file path, `http(s)://`)
  - `systemNotification?` (boolean, default `true`): when `false`, only Dynamic Island feed is updated

Notes:

- For extensions with `capabilities.notificationFeed: true`, sent notifications are mirrored into the shared Dynamic Island Notifications feed.

### `DynamicIsland.http`

- `fetch(url, options?) -> Promise<{ status, data, text, error? }>`

`options`:

- `method` (default GET)
- `headers` (`Record<string, string>`)
- `body` (string)

Notes:

- Requires `"network"` permission.
- Without permission, `fetch` throws.
- Network errors return a resolved object with `error`.

### `DynamicIsland.system`

- `getAIUsage()` -> usage object or `null`
- `getLatestNotification()` -> latest mirrored notification object or `null`
- `getRecentNotifications(limit?)` -> mirrored notifications array (newest first)
- `getWhatsAppWeb(limit?)` -> WhatsApp Web bridge state + recent parsed messages (requires `"network"`)
- `startWhatsAppWeb()` -> starts the WhatsApp Web bridge (requires `"network"`)
- `refreshWhatsAppWebQR()` -> reloads WhatsApp Web and refreshes QR code (requires `"network"`)
- `sendWhatsAppWebMessage(recipient, message)` -> queues message send via the logged-in WhatsApp Web session (requires `"network"`)

Notes:

- Requires `"usage"` for `getAIUsage`.
- Requires `"notifications"` for mirrored notification APIs.
- Requires `"network"` for WhatsApp Web bridge APIs.
- Data source precedence (aligned with CodexBar-style sources):
  - Codex: local summary files, then ChatGPT OAuth usage API (`/backend-api/wham/usage`) via `~/.codex/auth.json` token.
  - Claude: local summary files, then Claude OAuth usage API (`/api/oauth/usage`), then local stats cache fallback.
- `codex.source` and `claude.source` indicate where each payload came from (`local-summary`, `oauth-api`, `auth-token`, `stats-cache`, `unavailable`).
- Mirrored notification APIs require `"notifications"` permission and return entries shaped like:
  - `{ id, localID, appName, bundleIdentifier, appIcon, appIconURL, title, body, senderName, previewText, avatarURL, timestamp }`
  - `previewText`/`avatarURL` are best-effort and depend on what macOS exposes for that notification (privacy settings can hide previews).

### `DynamicIsland.playFeedback(type)`

`type` supported:

- `"success"`
- `"warning"`
- `"error"`
- `"selection"`

### `DynamicIsland.openURL(url)`

Opens URL in default browser.

## 6. Global Timer and Console APIs

Available in extension JS context:

- `setInterval(callback, ms)`
- `setTimeout(callback, ms)`
- `clearInterval(id)`
- `clearTimeout(id)`
- `console.log(...args)`
- `console.warn(...args)`
- `console.error(...args)`

Notes:

- Minimum timer interval is ~10ms.
- Console output appears in extension logs in the app settings UI.

## 7. `View` Global (Declarative UI DSL)

Use `View.*` helpers to build UI nodes (no HTML/DOM).

### Layout

- `View.hstack(children, { spacing?, align?, distribution? })`
- `View.vstack(children, { spacing?, align?, distribution? })`
- `View.zstack(children)`
- `View.spacer(minLength?)`
- `View.scroll(child, { axes?, showsIndicators? })`

Alignment values:

- `hstack.align`: `top | center | bottom`
- `vstack.align`: `leading | center | trailing`
- `distribution`: `natural | fillEqually` (`fillEqually` makes each direct child consume equal space along the stack axis)
- `scroll.axes`: `vertical | horizontal | both`

### Content

- `View.text(value, { style?, color?, lineLimit? })`
- `View.icon(name, { size?, color? })`
- `View.image(url, { width, height, cornerRadius? })`
- `View.progress(value, { total?, color? })`
- `View.circularProgress(value, { total?, lineWidth?, color? })`
- `View.gauge(value, { min?, max?, label? })`
- `View.divider()`

Text styles:

- `largeTitle`, `title`, `body`, `caption`, `footnote`, `monospaced`, `monospacedSmall`

Color values:

- Named: `white`, `gray`, `red`, `green`, `blue`, `yellow`, `orange`, `purple`, `pink`, `teal`, `cyan`
- RGBA object: `{ r, g, b, a? }` (0..1)

### Interactive

- `View.button(labelNode, actionID)`
- `View.toggle(isOn, label, actionID)`
- `View.slider(value, min, max, actionID)`

Action payloads:

- Button: `onAction(actionID)`
- Toggle: `onAction(actionID, boolean)`
- Slider: `onAction(actionID, number)` (sent when drag ends)

### Decorators

- `View.padding(child, { edges?, amount? })`
- `View.frame(child, { width?, height?, maxWidth?, maxHeight? })`
- `View.opacity(child, value)`
- `View.background(child, color)`
- `View.cornerRadius(child, radius)`
- `View.animate(child, kind)` where kind is commonly `pulse | bounce | spin | blink`

### Conditional and Utilities

- `View.when(condition, thenNode, elseNode?)`
- `View.timerText(seconds, { style? })`

Returning `null` from child positions is supported (treated as empty).

## 8. `settings.json` Schema

Supported field types:

- `toggle`
- `slider`
- `stepper`
- `picker`
- `text`
- `color`

Schema shape:

```json
{
  "sections": [
    {
      "title": "General",
      "fields": [
        {
          "type": "toggle",
          "key": "enabled",
          "label": "Enabled",
          "default": true
        }
      ]
    }
  ]
}
```

Field properties (type-dependent):

- `key` (required)
- `label` (required)
- `default`
- `min`, `max`, `step` (slider/stepper)
- `options: [{ value, label }]` (picker)

## 9. Discovery and Activation (Host Behavior)

The host scans extension directories and loads any folder containing `manifest.json` + `main` JS file.

Common scan locations:

- `<repo>/Extensions` (development)
- `<cwd>/Extensions`
- `<cwd>/ExtensionsDev`
- `~/Library/Application Support/DynamicIsland/Extensions`

If duplicate IDs are found, first discovered wins and duplicates are logged.

## 10. Permissions and Sandbox Notes

Sandbox behavior in current runtime:

- `eval` and `Function` are removed from global scope.
- JS runs in isolated JavaScriptCore context.
- `network` permission is enforced for `DynamicIsland.http.fetch`.
- `usage` permission is enforced for `DynamicIsland.system.getAIUsage`.
- `notifications` permission is enforced for `DynamicIsland.system.getLatestNotification` and `DynamicIsland.system.getRecentNotifications`.

Other permission names are currently metadata for compatibility/future policy, but should still be declared correctly in `manifest.json`.

## 11. Troubleshooting

### Extension not showing up

Check:

- `manifest.json` exists.
- `main` file exists (for example `index.js`).
- `id` is unique.
- Open Settings -> Extensions and review source paths/logs.

### Only 1-minute timer behavior

If a numeric setting is unset (`null`) and code uses `Number(value)` directly, it may become `0` unexpectedly. Use explicit null/undefined fallback handling.

### `island.activate(false)` seems missed on timer completion

If activation is triggered during transient host/menu transitions, call `activate(false)` and schedule a short retry (`~100-150ms`) for reliability.

### Extension crashes on store/set

Do not pass unsupported complex host objects. Stick to scalars, arrays, and plain objects.

## 12. Recommended Builder Pattern

- Keep module state in plain JS variables.
- Persist checkpoints via `DynamicIsland.store`.
- Keep render functions pure and fast.
- Use action IDs as stable command names (`start`, `pause`, `reset`, etc.).
- Declare only required permissions.

---

If you want, a good next step is adding a small extension starter template (`manifest.json + index.js + settings.json`) under `Extensions/template/` for new contributors.
