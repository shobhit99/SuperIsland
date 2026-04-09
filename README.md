<p align="center">
  <img src="assets/logo.png" width="96" height="96" alt="SuperIsland" />
</p>

<h1 align="center">SuperIsland</h1>

<p align="center">
  Transform your Mac's notch into a live, interactive island.<br />
  Now Playing · Battery · Weather · Calendar · Notifications · Extensions
</p>

<p align="center">
  <a href="https://dynamicisland.app">Website</a> ·
  <a href="https://dynamicisland.app/docs">Docs</a> ·
  <a href="https://github.com/shobhit99/superisland/releases">Releases</a>
</p>

---

## Requirements

- macOS 14 Sonoma or later
- Xcode 15+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`
- Node.js 18+ (only needed to work on extensions)

---

## Setup

```bash
git clone https://github.com/shobhit99/superisland.git
cd superisland
xcodegen generate
open SuperIsland.xcodeproj
```

Select the `SuperIsland` scheme, choose your Mac as the destination, and hit Run.

> On first launch the app will ask for Accessibility, Calendar, and Location permissions. These are required for the relevant modules to work.

---

## Building a release DMG

Requires a Developer ID certificate and notarization credentials. Copy `.env.example` to `.env` and fill in:

```
APPLE_ID=you@example.com
APP_SPECIFIC_PASSWORD=xxxx-xxxx-xxxx-xxxx
TEAM_ID=XXXXXXXXXX
SIGNING_IDENTITY=Developer ID Application: Your Name (TEAMID)
```

Then run:

```bash
./scripts/build-and-release.sh
```

This archives, exports, notarizes, and produces a signed `build/SuperIsland.dmg`.

For a quick unsigned local build:

```bash
./scripts/build-dmg.sh
```

---

## Project structure

```
SuperIsland/
  App/              AppDelegate, AppState
  Modules/          Built-in modules (Battery, NowPlaying, Weather, …)
  Settings/         Settings window views
  Utilities/        UpdateChecker, AutoUpdater, helpers
  Views/            CompactView, ExpandedView, IslandWindow
ExtensionHost/      JS runtime, extension manager, bridge
Extensions/         Bundled extensions (pomodoro, whatsapp-web, …)
scripts/            Build & release scripts
```

---

## Extensions

Extensions are JavaScript packages that run inside a sandboxed JavaScriptCore context. Read the full guide at [dynamicisland.app/docs](https://dynamicisland.app/docs) or in [EXTENSIONS.md](EXTENSIONS.md).

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

---

## Updates

SuperIsland checks for updates automatically on launch. When a new version is available a dialog appears — click **Update** to download and install without reinstalling.
