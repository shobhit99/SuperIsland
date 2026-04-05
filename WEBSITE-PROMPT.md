# Super Island for Mac — Website & Documentation Build Prompt

## Overview

Build a marketing website + Fumadocs-powered API documentation site for **Super Island for Mac** — a native macOS app that transforms the MacBook notch into an interactive, living widget surface. The site should be a single Next.js 15 app with two sections: a landing/marketing page and a `/docs` section powered by Fumadocs.

**Tech stack:** Next.js 15 (App Router), Fumadocs (`npm create fumadocs-app`), Tailwind CSS 4, Framer Motion, TypeScript.

---

## 1. Design Language

### Theme
- **Dark-only.** No light mode toggle. The entire site is pitch black (`#000000` body) with subtle grays, like the Super Island pill itself.
- Typography: Inter or Geist Sans for body, Geist Mono for code. Clean, tight line-heights.
- Accent color: a subtle warm white (`#E8E8E8`) for primary text, muted gray (`#888`) for secondary. Use color sparingly — only for interactive states, badges, and the pill accent glow.
- All cards/surfaces use `rgba(255,255,255,0.04)` backgrounds with `1px solid rgba(255,255,255,0.06)` borders. No heavy borders anywhere.
- Rounded corners everywhere (12–16px on cards, pill-shape on buttons/badges).
- Subtle glow effects: use `box-shadow: 0 0 60px rgba(255,255,255,0.03)` on hero elements.
- No gradients except on the island pill surface itself (which uses a subtle top-to-bottom `black 98% → black 94%` like the real app).
- Motion: all transitions are spring-based (`spring(response: 0.48, dampingFraction: 0.8)` equivalent in Framer Motion). Nothing should feel linear or abrupt.

### The Island Component (Hero Element)
Build a pixel-accurate CSS/SVG replica of the Super Island pill that lives at the top-center of the hero section. This is the centerpiece of the entire site.

**Exact specifications from the app:**
- Default compact size: `200px × 36px`
- Expanded size: `408px × 88px`
- Full expanded size: `658px × 180px`
- Corner radius (compact): `18px`
- Corner radius (expanded): `22px`
- Corner radius (full expanded): `40px`
- Background: `linear-gradient(to bottom, rgba(0,0,0,0.98), rgba(0,0,0,0.94))`
- Shadow (compact): `0 2px 3px rgba(0,0,0,0.18), 0 4px 5px rgba(0,0,0,0.32)`
- Shadow (expanded): `0 6px 8px rgba(0,0,0,0.38), 0 10px 14px rgba(0,0,0,0.58)`

**The island should animate between states** on the hero page — start compact showing a mock "Now Playing" view (album art thumbnail, song title marquee, play/pause icon), then smoothly expand to show mock expanded content on scroll or a timed loop. Use Framer Motion `layout` animations with spring physics.

**Compact Now Playing mock content:**
- Left: 26×26px rounded-rect (8px radius) album art placeholder (a gradient square)
- Center: marquee-scrolling song title text in `13px` white
- Right: play/pause SF Symbol equivalent icon

---

## 2. Site Structure

### Top Navigation Bar
Fixed, transparent, blurred background (`backdrop-filter: blur(20px)`). Contains:

| Left | Center | Right |
|------|--------|-------|
| Logo ("Super Island" wordmark, clean sans-serif) | — | Three buttons in a row |

**Three top-right buttons:**
1. **Download** — Primary CTA. Pill-shaped, white background, black text. Links to GitHub releases or direct `.dmg` download. Icon: `arrow.down.circle` equivalent.
2. **GitHub** — Ghost button (transparent bg, subtle border). Links to the GitHub repo. Icon: GitHub mark.
3. **Documentation** — Ghost button. Links to `/docs`. Icon: `book` equivalent.

### Page Sections (scrollable, single-page marketing)

#### Hero Section
- The animated Super Island pill at the top center, floating with a subtle shadow
- Below the pill: headline "Your Mac's notch, reimagined." in large (48–56px), tight weight
- Subheadline: "Super Island brings iOS-style live activities to macOS. Music, battery, notifications, calendar — all living in your notch." in muted gray, 18px
- Two CTA buttons below: "Download for macOS" (primary) and "View on GitHub" (ghost)
- Requires macOS 14+ badge in small muted text

#### Features Grid
A responsive grid (3 columns on desktop, 1 on mobile) showcasing all built-in modules. Each card is a dark surface with an icon, title, and one-line description:

1. **Now Playing** — Icon: `music.note`. "See what's playing. Control playback. Album art, artist, and track info — all in your notch."
2. **Battery** — Icon: `battery.75percent`. "Glanceable battery level with charging status and time remaining."
3. **Calendar** — Icon: `calendar`. "Your next meeting at a glance. Countdown to upcoming events with join links."
4. **Weather** — Icon: `cloud.sun`. "Current conditions and temperature, updated every 30 minutes."
5. **Notifications** — Icon: `bell`. "macOS notifications displayed beautifully in the island with app icons and sender info."
6. **Connectivity** — Icon: `wifi`. "Wi-Fi network name, signal strength, and Bluetooth device status."
7. **Volume & Brightness** — Icon: `speaker.wave.2`. "Native HUD replacement. See volume and brightness changes in the island instead of the system overlay."
8. **Shelf** — Icon: `tray`. "Drag and drop files, images, or text onto the island for quick access later."
9. **Focus Mode** — Icon: `moon`. "See your current Focus mode status at a glance."

#### How It Works Section
Three-step visual explanation with the island pill shown in each state:

1. **Compact** — "Lives in your notch. Always-on, minimal info at a glance." Show the pill at `200×36px`.
2. **Expanded** — "Hover or tap to see more. Quick controls and details." Show at `408×88px`.
3. **Full Expanded** — "The full experience. Rich controls, detailed info, interactive content." Show at `658×180px`.

Each step shows the island with appropriate mock content and a brief description. Animate between steps on scroll using intersection observer + Framer Motion.

#### Extension SDK Section
This is the key developer-facing section. Dark card with a code editor aesthetic.

- Headline: "Build your own modules."
- Subheadline: "JavaScript SDK with a declarative view system. Write extensions that render natively in SwiftUI."
- Show a syntax-highlighted code example of a minimal extension (use the Pomodoro timer as inspiration):

```javascript
SuperIsland.registerModule({
  compact() {
    return View.hstack([
      View.icon("brain.head.profile", { size: 12, color: "white" }),
      View.text("25:00", { style: "monospaced", color: "white" }),
    ], { spacing: 6 });
  },

  expanded() {
    return View.hstack([
      View.mascot({ size: 50 }),
      View.vstack([
        View.text("Focus", { style: "title", color: "white" }),
        View.text("25:00", { style: "monospaced", color: "white" }),
      ], { spacing: 3, align: "leading" }),
    ], { spacing: 10 });
  },

  onAction(actionID) {
    if (actionID === "toggle") toggleTimer();
  }
});
```

- Below the code: a "Read the docs →" link to `/docs`
- List of example extensions the community could build: Pomodoro Timer, CPU Monitor, Stock Ticker, GitHub Notifications, Spotify Lyrics, Meeting Countdown, Clipboard History, Smart Home Controls

#### Mascot Section (brief)
- "Meet your island companion." — mention the animated mascot system (Rive-powered characters that react to what you're doing). Keep it light, one visual + one sentence.

#### Footer
Minimal. Links: GitHub, Documentation, Download, License (MIT or whatever applies). Copyright line.

---

## 3. Fumadocs Documentation (`/docs`)

Set up Fumadocs with MDX content source. The docs section should use the **Docs Layout** with the default dark theme (Fumadocs has built-in dark mode — force it via CSS/config). Override Fumadocs theme colors to match the site's pitch-black aesthetic.

### Docs Sidebar Structure

```
Getting Started
├── Introduction
├── Installation
├── System Requirements
└── First Launch

Built-in Modules
├── Now Playing
├── Battery
├── Calendar
├── Weather
├── Notifications
├── Connectivity
├── Volume & Brightness HUD
├── Shelf (Drag & Drop)
└── Focus Mode

Gestures & Interaction
├── Hover & Expand
├── Swipe Navigation
├── Long Press (Settings)
├── Drag & Drop (Shelf)
└── Module Cycling

Appearance & Settings
├── Idle Opacity
├── Launch at Login
├── Screen Recording Visibility
└── Notch Haptic Feedback

Extension SDK
├── Overview
├── Quick Start
├── manifest.json Reference
├── Extension Lifecycle
├── View API Reference
│   ├── Layout (hstack, vstack, zstack, spacer, scroll)
│   ├── Content (text, markdownText, icon, image, divider)
│   ├── Data Display (progress, circularProgress, gauge)
│   ├── Controls (button, toggle, slider, inputBox)
│   ├── Modifiers (padding, frame, opacity, background, cornerRadius, animation)
│   ├── Mascot
│   └── Conditional (when / if)
├── SuperIsland API Reference
│   ├── Module Registration
│   ├── Store (Persistent Storage)
│   ├── Settings (User Preferences)
│   ├── Island Controls (activate, dismiss)
│   ├── Notifications
│   ├── HTTP (Network Requests)
│   ├── System (AI Usage, Notifications Access)
│   ├── Mascot Control
│   ├── Feedback (Haptics)
│   ├── Open URL
│   └── Console Logging
├── Display Modes
│   ├── compact
│   ├── expanded
│   ├── fullExpanded
│   ├── minimalLeading & minimalTrailing
│   └── Notification Feed Mode
├── Settings Schema (settings.json)
├── Permissions
├── Sandbox & Security
├── Built-in Components
└── Example Extensions
    ├── Pomodoro Timer
    ├── AI Usage Rings
    └── Building Your First Extension
```

### Documentation Content

Below is the detailed content for each documentation page. Write each as an MDX file with proper Fumadocs frontmatter (`title`, `description`).

---

#### Getting Started / Introduction
```
---
title: Introduction
description: Super Island for Mac transforms your MacBook notch into a living widget surface.
---
```

Super Island is a native macOS app (Swift/SwiftUI, macOS 14+) that transforms the MacBook notch area into an interactive Super Island — inspired by iPhone's Super Island. It lives in your notch and surfaces information from 9 built-in modules: Now Playing, Battery, Calendar, Weather, Notifications, Connectivity, Volume/Brightness HUD, Shelf, and Focus Mode.

The island has three states:
- **Compact** (`200×36pt`) — always visible in the notch, showing minimal info
- **Expanded** (`408×88pt`) — hover/tap to reveal more detail and quick controls
- **Full Expanded** (`658×180pt`) — rich interactive panel with full controls

The app is fully extensible via a JavaScript SDK. Third-party extensions run in a sandboxed JavaScriptCore runtime and describe their UI declaratively — the host app renders them natively in SwiftUI.

---

#### Getting Started / Installation

How to download, install the `.app` bundle, grant necessary permissions (Accessibility, Notifications), and first-launch configuration.

---

#### Getting Started / System Requirements

- macOS 14 (Sonoma) or later
- Works best on MacBooks with a notch (2021+), but also works on non-notch Macs (pill floats at top-center of screen)
- Apple Silicon or Intel

---

#### Extension SDK / manifest.json Reference

This is the most critical API reference page. Document the full `manifest.json` schema:

```json
{
  "id": "com.author.extension-name",
  "name": "Extension Display Name",
  "version": "1.0.0",
  "minAppVersion": "1.0.0",
  "main": "index.js",
  "author": {
    "name": "Author Name",
    "url": "https://example.com"
  },
  "description": "One-line description of what this extension does.",
  "icon": "icon.svg",
  "license": "MIT",
  "categories": ["productivity", "developer"],
  "permissions": ["network", "storage", "notifications", "usage"],
  "capabilities": {
    "compact": true,
    "expanded": true,
    "fullExpanded": true,
    "minimalCompact": false,
    "backgroundRefresh": true,
    "settings": true,
    "notificationFeed": false
  },
  "refreshInterval": 1.0,
  "activationTriggers": ["manual", "timer"]
}
```

Document each field with its type, default value, and description. Use a Fumadocs TypeTable or a styled table.

**Field documentation:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `id` | `string` | *required* | Reverse-domain identifier. Must be unique across all extensions. |
| `name` | `string` | *required* | Human-readable name shown in settings and module cycler. |
| `version` | `string` | *required* | Semver version string. |
| `minAppVersion` | `string` | `"1.0.0"` | Minimum Super Island app version required. |
| `main` | `string` | `"index.js"` | Path to the entry JavaScript file relative to the extension bundle. |
| `author` | `object` | `null` | Author info with `name` (string) and optional `url` (string). |
| `description` | `string` | `""` | Short description shown in extension settings. |
| `icon` | `string` | `null` | Path to icon file (SVG or PNG) relative to bundle, or absolute path. |
| `license` | `string` | `null` | SPDX license identifier. |
| `categories` | `string[]` | `[]` | Categorization tags (e.g., `"productivity"`, `"developer"`, `"social"`, `"monitoring"`). |
| `permissions` | `string[]` | `[]` | Required permissions: `"network"`, `"storage"`, `"notifications"`, `"usage"`. |
| `capabilities.compact` | `boolean` | `true` | Whether the extension renders in compact (pill) state. |
| `capabilities.expanded` | `boolean` | `true` | Whether the extension renders in expanded state. |
| `capabilities.fullExpanded` | `boolean` | `true` | Whether the extension renders in full expanded state. |
| `capabilities.minimalCompact` | `boolean` | `false` | Whether the extension supports minimal notch layout (leading/trailing items flanking the hardware notch). |
| `capabilities.backgroundRefresh` | `boolean` | `true` | Whether the extension's render functions are called on a timer even when not the active module. |
| `capabilities.settings` | `boolean` | `true` | Whether the extension has configurable settings. |
| `capabilities.notificationFeed` | `boolean` | `false` | If true, the extension is hidden from module slots and feeds into the shared Notifications module instead. |
| `refreshInterval` | `number` | `1.0` | How often (in seconds) the extension's render functions are called. Minimum `0.1`. |
| `activationTriggers` | `string[]` | `["manual"]` | What triggers extension activation: `"manual"`, `"timer"`. |

---

#### Extension SDK / View API Reference

Document every `View.*` helper function. These are injected globally and available in every extension's JavaScript context.

##### Layout Views

**`View.hstack(children, options?)`**
Horizontal stack layout.
- `children`: `ViewNode[]` — array of child views
- `options.spacing`: `number` — gap between children (default: `8`)
- `options.align`: `string` — vertical alignment: `"top"`, `"center"`, `"bottom"` (default: `"center"`)
- `options.distribution`: `string` — `"natural"` (default)

**`View.vstack(children, options?)`**
Vertical stack layout.
- `children`: `ViewNode[]`
- `options.spacing`: `number` (default: `4`)
- `options.align`: `string` — horizontal alignment: `"leading"`, `"center"`, `"trailing"` (default: `"center"`)
- `options.distribution`: `string` — `"natural"` (default)

**`View.zstack(children)`**
Overlay stack. Children are layered on top of each other.
- `children`: `ViewNode[]`

**`View.spacer(minLength?)`**
Flexible space that pushes siblings apart.
- `minLength`: `number | undefined`

**`View.scroll(child, options?)`**
Scrollable container.
- `child`: `ViewNode`
- `options.axes`: `string` — `"vertical"` (default) or `"horizontal"`
- `options.showsIndicators`: `boolean` (default: `true`)

##### Content Views

**`View.text(value, options?)`**
Text label.
- `value`: `string`
- `options.style`: `TextStyle` — `"largeTitle"` (26px semibold), `"title"` (16px semibold), `"headline"` (14px semibold), `"body"` (13px), `"caption"` (11px), `"footnote"` (10px), `"monospaced"` (14px mono medium), `"monospacedSmall"` (11px mono) (default: `"body"`)
- `options.color`: `ColorValue` — named color string or `{ r, g, b, a }` object (default: `"white"`)
- `options.lineLimit`: `number | undefined` — max number of lines before truncation

**`View.markdownText(value, options?)`**
Renders markdown-formatted text. Same options as `View.text`.

**`View.icon(name, options?)`**
SF Symbol icon (uses macOS system symbols).
- `name`: `string` — SF Symbol name (e.g., `"play.fill"`, `"brain.head.profile"`)
- `options.size`: `number` (default: `14`)
- `options.color`: `ColorValue` (default: `"white"`)

**`View.image(url, options)`**
Remote or local image.
- `url`: `string`
- `options.width`: `number` (default: `16`)
- `options.height`: `number` (default: `16`)
- `options.cornerRadius`: `number` (default: `0`)

**`View.divider()`**
Horizontal separator line.

##### Data Display Views

**`View.progress(value, options?)`**
Linear progress bar.
- `value`: `number` — current value
- `options.total`: `number` (default: `1`)
- `options.color`: `ColorValue` (default: `"white"`)

**`View.circularProgress(value, options?)`**
Circular progress ring.
- `value`: `number`
- `options.total`: `number` (default: `1`)
- `options.lineWidth`: `number` (default: `3`)
- `options.color`: `ColorValue`

**`View.gauge(value, options?)`**
Gauge indicator.
- `value`: `number`
- `options.min`: `number` (default: `0`)
- `options.max`: `number` (default: `1`)
- `options.label`: `string | undefined`

**`View.timerText(seconds, options?)`**
Formatted `MM:SS` timer display. Convenience wrapper around `View.text`.
- `seconds`: `number`
- `options.style`: `TextStyle` (default: `"monospaced"`)

##### Interactive Controls

**`View.button(label, actionID)`**
Tappable button. Triggers `onAction(actionID)` when clicked.
- `label`: `ViewNode` — any view as the button content
- `actionID`: `string` — identifier passed to `onAction`

**`View.inputBox(placeholder, text, actionID, options?)`**
Text input field. Triggers `onAction(actionID, inputText)` on submit.
- `placeholder`: `string`
- `text`: `string` — current text value
- `actionID`: `string`
- `options.id`: `string` — unique identifier for the input
- `options.autoFocus`: `boolean` (default: `true`)
- `options.minHeight`: `number` (default: `72`)
- `options.showsEmojiButton`: `boolean` (default: `false`)

**`View.toggle(isOn, label, actionID)`**
Toggle switch. Triggers `onAction(actionID, boolValue)`.
- `isOn`: `boolean`
- `label`: `string`
- `actionID`: `string`

**`View.slider(value, min, max, actionID)`**
Slider control. Triggers `onAction(actionID, numericValue)`.
- `value`: `number`
- `min`: `number`
- `max`: `number`
- `actionID`: `string`

##### View Modifiers

**`View.padding(child, options?)`**
Adds padding around a child view.
- `child`: `ViewNode`
- `options.edges`: `string` — `"all"` (default), `"horizontal"`, `"vertical"`, `"top"`, `"bottom"`, `"leading"`, `"trailing"`
- `options.amount`: `number` (default: `8`)

**`View.frame(child, options?)`**
Constrains size.
- `child`: `ViewNode`
- `options.width`: `number | undefined`
- `options.height`: `number | undefined`
- `options.maxWidth`: `number | undefined`
- `options.maxHeight`: `number | undefined`
- `options.alignment`: `string` — `"center"` (default), `"leading"`, `"trailing"`, `"top"`, `"bottom"`

**`View.opacity(child, value)`**
Sets opacity.
- `child`: `ViewNode`
- `value`: `number` (0–1)

**`View.background(child, color)`**
Fills background.
- `child`: `ViewNode`
- `color`: `ColorValue`

**`View.cornerRadius(child, radius)`**
Clips to rounded rectangle.
- `child`: `ViewNode`
- `radius`: `number`

**`View.animate(child, kind)`**
Applies looping animation.
- `child`: `ViewNode`
- `kind`: `string` — `"pulse"`, `"bounce"`, `"blink"`

##### Special Views

**`View.mascot(options?)`**
Renders the user's selected animated mascot character.
- `options.size`: `number` (default: `60`)
- `options.expression`: `string | undefined` — override expression (e.g., `"idle"`, `"working"`)

**`View.when(condition, thenNode, elseNode?)`**
Conditional rendering. Returns `thenNode` if condition is truthy, `elseNode` (or null) otherwise.

##### Color Values
Colors can be specified as:
- Named string: `"white"`, `"gray"`, `"red"`, `"green"`, `"blue"`, `"yellow"`, `"orange"`, `"purple"`, `"pink"`, `"teal"`, `"cyan"`
- RGBA object: `{ r: 0.4, g: 0.87, b: 0.55, a: 1.0 }` (values 0–1)

---

#### Extension SDK / SuperIsland API Reference

Document the global `SuperIsland` namespace available in every extension.

##### Module Registration

**`SuperIsland.registerModule(config)`**

Registers the extension module. This must be called exactly once during script evaluation.

```javascript
SuperIsland.registerModule({
  // Lifecycle hooks
  onActivate() { },
  onDeactivate() { },

  // Action handler — called when buttons/toggles/sliders/inputs are interacted with
  onAction(actionID, value) { },

  // Render functions — return ViewNode trees
  compact() { return View.text("Hello"); },
  expanded() { return View.text("Hello Expanded"); },
  fullExpanded() { return View.text("Hello Full"); },  // optional

  // Minimal compact — for notched Macs, renders flanking the hardware notch
  minimalCompact: {  // optional
    leading() { return View.icon("star.fill", { size: 14 }); },
    trailing() { return View.text("Hi", { style: "caption" }); },
    precedence: 1  // or a function returning a number — lower = higher priority vs Now Playing
  }
});
```

##### Persistent Storage — `SuperIsland.store`

Key-value store persisted across app launches. Namespaced per extension.

- **`SuperIsland.store.get(key)`** — Returns stored value or `null`
- **`SuperIsland.store.set(key, value)`** — Stores a JSON-serializable value

##### User Settings — `SuperIsland.settings`

Read user-configured settings (defined by `settings.json`).

- **`SuperIsland.settings.get(key)`** — Returns setting value or `null`
- **`SuperIsland.settings.set(key, value)`** — Programmatically update a setting

##### Island Controls — `SuperIsland.island`

Control the island's presentation state.

- **`SuperIsland.island.activate(autoDismiss?)`** — Expand the island to show this extension. `autoDismiss` defaults to `true`.
- **`SuperIsland.island.dismiss()`** — Collapse the island back to compact state.
- **`SuperIsland.island.state`** — Read-only string: `"compact"`, `"expanded"`, or `"fullExpanded"`
- **`SuperIsland.island.isActive`** — Read-only boolean: whether this extension is the currently displayed module.

##### Notifications — `SuperIsland.notifications`

**`SuperIsland.notifications.send(options)`**

Post a notification that appears in the island and optionally as a system notification.

```javascript
SuperIsland.notifications.send({
  title: "Timer Complete",
  body: "Your 25-minute focus session is done.",
  sound: true,
  appName: "Pomodoro",            // optional
  bundleIdentifier: "com.app.id", // optional — shows app icon
  senderName: "Timer",            // optional
  previewText: "Take a break",    // optional
  avatarURL: "https://...",       // optional — sender avatar
  appIconURL: "https://...",      // optional — app icon override
  id: "timer-complete",           // optional — dedup/dismiss identifier
  systemNotification: true,       // optional, default true
  tapAction: {                    // optional
    type: "url",
    value: "https://example.com"
  }
});
```

##### HTTP — `SuperIsland.http`

**Requires `"network"` permission.**

**`SuperIsland.http.fetch(url, options?)`**

Synchronous HTTP fetch (runs on the JS thread). Returns a response object.

```javascript
var response = SuperIsland.http.fetch("https://api.example.com/data", {
  method: "GET",
  headers: { "Authorization": "Bearer token" },
  body: null,
  timeout: 5
});
// response = { status: 200, headers: {...}, body: "..." }
```

##### System — `SuperIsland.system`

**`SuperIsland.system.getAIUsage()`** — Requires `"usage"` permission. Returns Claude and Codex usage data including remaining percentages, reset times, and plan info.

**`SuperIsland.system.getLatestNotification()`** — Requires `"notifications"` permission. Returns the most recent macOS notification as an object.

**`SuperIsland.system.getRecentNotifications(limit?)`** — Requires `"notifications"` permission. Returns array of recent notifications (default limit: 20, max: 100).

**`SuperIsland.system.dismissNotification(sourceID)`** — Dismiss a notification by its source ID.

**`SuperIsland.system.closePresentedInteraction()`** — Close any interaction panel presented by this extension.

##### Mascot — `SuperIsland.mascot`

Control the animated mascot character.

- **`SuperIsland.mascot.setExpression(name)`** — Set mascot expression (e.g., `"idle"`, `"working"`, `"happy"`)
- **`SuperIsland.mascot.getExpression()`** — Get current expression name
- **`SuperIsland.mascot.getSelected()`** — Returns `{ slug, name }` of the selected mascot
- **`SuperIsland.mascot.list()`** — Returns array of `{ slug, name }` for all available mascots
- **`SuperIsland.mascot.setInput(name, value)`** — Set a Rive input on the mascot animation

##### Feedback

- **`SuperIsland.playFeedback(type)`** — Play haptic feedback. Types: `"success"`, `"warning"`, `"error"`, `"selection"`
- **`SuperIsland.openURL(url)`** — Open a URL in the default browser

##### Console

Standard `console` is available:
- `console.log(...args)`
- `console.warn(...args)`
- `console.error(...args)`

Logs are visible in the extension debug console within app settings.

##### Timers

Standard timer APIs are available in the global scope:
- `setInterval(callback, ms)` → returns timer ID
- `setTimeout(callback, ms)` → returns timer ID
- `clearInterval(id)`
- `clearTimeout(id)`

---

#### Extension SDK / Settings Schema

Extensions can provide a `settings.json` file alongside `manifest.json` to expose user-configurable settings.

```json
{
  "sections": [
    {
      "title": "Timer",
      "fields": [
        {
          "type": "slider",
          "key": "workDuration",
          "label": "Focus Duration (minutes)",
          "min": 5,
          "max": 90,
          "step": 5,
          "default": 25
        },
        {
          "type": "toggle",
          "key": "notifyOnComplete",
          "label": "Notify when timer completes",
          "default": true
        },
        {
          "type": "picker",
          "key": "theme",
          "label": "Color Theme",
          "default": "warm",
          "options": [
            { "value": "warm", "label": "Warm Orange" },
            { "value": "cool", "label": "Cool Blue" }
          ]
        },
        {
          "type": "text",
          "key": "apiKey",
          "label": "API Key"
        },
        {
          "type": "stepper",
          "key": "maxSessions",
          "label": "Daily session goal",
          "min": 1,
          "max": 20,
          "step": 1,
          "default": 8
        }
      ]
    }
  ]
}
```

**Supported field types:** `toggle`, `slider`, `stepper`, `picker`, `text`, `color`

Settings values are read in the extension via `SuperIsland.settings.get("key")`.

---

#### Extension SDK / Permissions

Document the permission model:

| Permission | Description | Grants Access To |
|-----------|-------------|-----------------|
| `network` | Make HTTP requests to external APIs | `SuperIsland.http.fetch()`, WhatsApp Web bridge |
| `storage` | Persist data across sessions | `SuperIsland.store.get/set()` (always available, but this explicitly declares intent) |
| `notifications` | Send notifications and read system notifications | `SuperIsland.notifications.send()`, `SuperIsland.system.getLatestNotification()`, `SuperIsland.system.getRecentNotifications()` |
| `usage` | Read AI tool usage data (Claude, Codex) | `SuperIsland.system.getAIUsage()` |

---

#### Extension SDK / Sandbox & Security

Extensions run in a JavaScriptCore sandbox with the following restrictions:
- `eval()` and `Function()` constructor are removed
- No direct filesystem access
- No DOM or browser APIs
- Network access requires explicit `"network"` permission
- All UI is declarative (ViewNode trees) — no direct SwiftUI/AppKit access
- Extensions cannot access other extensions' storage (namespaced by extension ID)

---

#### Extension SDK / Built-in Components

Document the `SuperIsland.components` namespace:

**`SuperIsland.components.shortcutHint()`**
Renders a keyboard shortcut hint bar showing "Enter to Send | Shift+Enter for New line".

**`SuperIsland.components.inputComposer(options?)`**
A pre-styled text input composer with optional error display and shortcut hints.

```javascript
SuperIsland.components.inputComposer({
  placeholder: "Type a message...",
  text: currentText,
  action: "send",
  id: "main-input",
  autoFocus: true,
  minHeight: 46,
  showsEmojiButton: true,
  showsShortcutHint: true,
  error: null,             // optional error message
  chrome: true,            // wraps in styled container
  padding: 6,
  backgroundColor: { r: 0, g: 0, b: 0, a: 0.28 },
  cornerRadius: 12,
  spacing: 4
});
```

---

#### Extension SDK / Display Modes

Explain the five display modes an extension can render in:

1. **`compact`** — The pill view. ~200×36pt. Always visible in the notch. Show minimal, glanceable info.
2. **`expanded`** — The drawer. 408×88pt. Shown on hover/tap. More detail + quick controls.
3. **`fullExpanded`** — The detail panel. 658×180pt. Full interactive surface. Rich controls, lists, inputs.
4. **`minimalLeading`** — Left side of the hardware notch. For notched Macs only. Typically an icon or small image.
5. **`minimalTrailing`** — Right side of the hardware notch. Typically a text label or small control.

Include a visual diagram showing the notch with leading/trailing zones.

---

#### Extension SDK / Example Extensions

##### Pomodoro Timer
Full walkthrough of building the Pomodoro extension. Cover:
- Setting up `manifest.json` with proper capabilities
- Using `SuperIsland.store` for state persistence
- Timer logic with `setInterval`/`clearInterval`
- Rendering in all three display modes
- Using `SuperIsland.mascot` to change expressions based on state
- Sending notifications on phase completion
- Playing haptic feedback
- Settings schema for configurable durations

##### AI Usage Rings
Brief example showing:
- Reading Claude/Codex usage via `SuperIsland.system.getAIUsage()`
- Rendering `View.circularProgress` rings
- Using `"usage"` permission
- 15-second refresh interval

---

## 4. Built-in Components to Use

Use these Fumadocs MDX components throughout the docs:

- `<Callout type="info|warn|error">` for important notes
- `<Steps>` for sequential instructions
- `<Tabs>` for showing code in multiple languages or variations
- `<TypeTable>` for documenting API parameter types
- `<Files>` for showing extension bundle file structure:
  ```
  my-extension/
  ├── manifest.json
  ├── index.js
  ├── settings.json (optional)
  └── icon.svg (optional)
  ```
- Syntax-highlighted code blocks with titles: ` ```js title="index.js" `

---

## 5. Key Implementation Notes

### Fumadocs Setup
1. `npm create fumadocs-app` — select Next.js + Fumadocs MDX
2. Force dark mode globally: in `layout.tsx`, set `<html class="dark">` and override Fumadocs CSS variables to use the pitch-black palette
3. Put all doc MDX files in `content/docs/` following the sidebar structure above
4. Configure `source.config.ts` for MDX content source
5. Customize the Fumadocs Docs Layout to remove any light-mode toggle

### Landing Page
- The landing page (`app/page.tsx`) is a custom page, NOT part of the Fumadocs layout
- It shares the same dark theme but uses a different layout (no sidebar)
- The animated island component should be a client component using Framer Motion
- Use intersection observer to trigger island state transitions on scroll

### Code Highlighting
- Use Shiki (built into Fumadocs) with a dark theme like `github-dark-dimmed` or `vitesse-dark`
- Add JavaScript/TypeScript and JSON as highlighted languages

### SEO
- Open Graph images: use Fumadocs dynamic OG image generation
- Title template: `%s — Super Island for Mac`
- Description: "Transform your MacBook's notch into a living widget surface."
