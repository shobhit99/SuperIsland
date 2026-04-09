# SuperIsland Extensions

Full docs at [dynamicisland.app/docs](https://dynamicisland.app/docs)

---

Extensions are JavaScript packages that run inside SuperIsland's sandboxed runtime. They can render UI in the compact pill, the expanded drawer, and the full detail panel — and run background logic to fetch or compute data.

---

## Extension structure

```
your-extension/
├── manifest.json       # Required — metadata and capabilities
├── index.js            # Required — extension logic
├── settings.json       # Optional — settings schema
└── assets/
    └── icon.svg        # Optional — shown in the extensions list
```

Drop your extension folder into `Extensions/` and it will be discovered automatically when you run the app.

---

## manifest.json

```json
{
  "id": "com.yourname.your-extension",
  "name": "My Extension",
  "version": "1.0.0",
  "minAppVersion": "1.0.0",
  "main": "index.js",
  "author": {
    "name": "Your Name",
    "url": "https://github.com/yourname"
  },
  "description": "One sentence about what this does.",
  "icon": "assets/icon.svg",
  "license": "MIT",
  "categories": ["productivity"],
  "permissions": ["storage", "network"],
  "capabilities": {
    "compact": true,
    "expanded": true,
    "fullExpanded": false,
    "backgroundRefresh": true,
    "settings": true
  },
  "refreshInterval": 5.0
}
```

**Permissions**

| Permission | What it unlocks |
|---|---|
| `storage` | `SuperIsland.store` key-value persistence |
| `network` | `SuperIsland.http.fetch()` |
| `notifications` | Send macOS notifications |

**Capabilities**

| Key | Description |
|---|---|
| `compact` | Render in the pill (≈188×34 pt) |
| `expanded` | Render in the drawer (360×80 pt) |
| `fullExpanded` | Render in the detail panel (400×200 pt) |
| `backgroundRefresh` | `onRefresh()` is called on the `refreshInterval` |
| `settings` | `settings.json` is read and surfaced in Settings |

---

## index.js — API reference

The `SuperIsland` global is injected before your script runs.

```js
// --- Rendering ---

// Set compact view (shown in the pill)
SuperIsland.island.setCompactView({
  left:   { type: "text", value: "25:00" },
  center: { type: "text", value: "Focus" },
  right:  { type: "icon", name: "timer" }
})

// Set expanded view (shown when island is tapped)
SuperIsland.island.setExpandedView({
  rows: [
    { type: "text", value: "Session 3 of 4", style: "title" },
    { type: "text", value: "25 minutes remaining", style: "subtitle" },
    {
      type: "buttons",
      items: [
        { label: "Pause",  action: "pause"  },
        { label: "Skip",   action: "skip"   },
        { label: "Reset",  action: "reset"  }
      ]
    }
  ]
})

// --- Lifecycle hooks ---

function onInit() {
  // Called once when the extension is loaded.
  // Restore persisted state, start timers, etc.
}

function onRefresh() {
  // Called every `refreshInterval` seconds (if backgroundRefresh: true).
  // Fetch data, update views.
}

function onAction(action) {
  // Called when the user taps a button in your expanded view.
  // `action` is the string from the button's `action` field.
  if (action === "pause") { /* … */ }
}

function onSettingsChanged(key, value) {
  // Called when the user changes a setting.
}

// Register your hooks:
SuperIsland.extension.onInit(onInit)
SuperIsland.extension.onRefresh(onRefresh)
SuperIsland.extension.onAction(onAction)
SuperIsland.extension.onSettingsChanged(onSettingsChanged)

// --- Storage ---

SuperIsland.store.set("key", "value")   // persist a value
SuperIsland.store.get("key")             // retrieve it (returns null if not set)

// --- Settings ---

SuperIsland.settings.get("myKey")        // read a value from settings.json schema

// --- Network ---

SuperIsland.http.fetch("https://api.example.com/data")
  .then(function(response) {
    var data = JSON.parse(response.body)
    // update views with data
  })

// --- Notifications ---

SuperIsland.notifications.send({
  title: "Time's up",
  body: "Take a break."
})

// --- Island control ---

SuperIsland.island.activate()    // bring the island to the foreground
SuperIsland.island.dismiss()     // collapse back to compact
```

---

## Full example — stock price ticker

```js
"use strict";

var symbol = "AAPL";
var price = "--";
var change = "--";

function onInit() {
  symbol = SuperIsland.settings.get("symbol") || "AAPL";
  render();
}

function onRefresh() {
  SuperIsland.http.fetch("https://query1.finance.yahoo.com/v8/finance/quote?symbols=" + symbol)
    .then(function(res) {
      var data = JSON.parse(res.body);
      var quote = data.quoteResponse.result[0];
      price  = "$" + quote.regularMarketPrice.toFixed(2);
      change = (quote.regularMarketChangePercent >= 0 ? "+" : "") +
               quote.regularMarketChangePercent.toFixed(2) + "%";
      render();
    });
}

function onSettingsChanged(key, value) {
  if (key === "symbol") {
    symbol = value;
    onRefresh();
  }
}

function render() {
  SuperIsland.island.setCompactView({
    left:   { type: "text", value: symbol },
    center: { type: "text", value: price  },
    right:  { type: "text", value: change }
  });

  SuperIsland.island.setExpandedView({
    rows: [
      { type: "text", value: symbol + "  " + price, style: "title"    },
      { type: "text", value: "Change: " + change,   style: "subtitle" }
    ]
  });
}

SuperIsland.extension.onInit(onInit);
SuperIsland.extension.onRefresh(onRefresh);
SuperIsland.extension.onSettingsChanged(onSettingsChanged);
```

**settings.json** for the above:

```json
{
  "sections": [
    {
      "title": "Stock",
      "fields": [
        {
          "type": "text",
          "key": "symbol",
          "label": "Ticker symbol",
          "placeholder": "AAPL",
          "default": "AAPL"
        }
      ]
    }
  ]
}
```

---

## Settings schema field types

| type | Options |
|---|---|
| `text` | `key`, `label`, `placeholder`, `default` |
| `toggle` | `key`, `label`, `default` (bool) |
| `slider` | `key`, `label`, `min`, `max`, `step`, `default` |
| `select` | `key`, `label`, `options` (array of `{label, value}`), `default` |

---

## Tips

- Keep your compact view minimal — the pill is small. One piece of key info per slot.
- Persist any state you'd want restored across app restarts using `SuperIsland.store`.
- Use `onRefresh` for polling. Avoid `setInterval` — the runtime controls scheduling.
- Test with the app running in Xcode; extension console logs appear in the Xcode output.
