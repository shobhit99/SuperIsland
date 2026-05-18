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

## Building a DMG

For a quick unsigned local build:

```bash
./scripts/build-dmg.sh
```

For a signed release, use a Developer ID certificate and notarization credentials. Copy `.env.template` to `.env` and fill in:

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

This archives a universal app, bundles a universal runtime, notarizes the DMG, and produces `build/SuperIsland.dmg`.

Release and Homebrew packaging notes are in [docs/RELEASE.md](docs/RELEASE.md). A Homebrew Cask template is available at [packaging/homebrew/superisland.rb](packaging/homebrew/superisland.rb).

To verify a built app bundle:

```bash
./scripts/verify-universal-build.sh build/SuperIsland.app --skip-signature
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

## Now Playing

Now Playing supports system media, Apple Music, Spotify, and opt-in browser media detection for supported Chromium browsers. See [docs/NOW_PLAYING.md](docs/NOW_PLAYING.md).

## Energy settings

Settings -> General -> Power includes Normal, Smart, and Low Power modes. Smart reduces background refresh while the island is collapsed, while Low Power slows non-essential work and pauses inactive extension timers. See [docs/ENERGY.md](docs/ENERGY.md) for profiling notes and scheduler behavior.

## Appearance

Home slots, compact island size, animation intensity, and reduced motion can be configured in Settings. See [docs/APPEARANCE.md](docs/APPEARANCE.md).

## Calendar

The Calendar module supports account/source selection, holiday and birthday filters, duplicate collapse, and meeting-link actions. See [docs/CALENDAR.md](docs/CALENDAR.md).

## File Shelf

The built-in Shelf module can stage local files, folders, URLs, text snippets, and images from the island. See [docs/SHELF.md](docs/SHELF.md).

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

---

## Updates

SuperIsland checks for updates automatically on launch. When a new version is available a dialog appears — click **Update** to download and install without reinstalling.
