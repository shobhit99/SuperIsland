# AI Prompt: Build "DynamicIsland" — A Native macOS Dynamic Island App

## Product Overview

Build a **native macOS application** called **"DynamicIsland"** (working name) that transforms the MacBook notch area (or top-center of non-notched Macs) into an interactive, always-on Dynamic Island — inspired by iOS's Dynamic Island, [DynamicLake](https://www.dynamiclake.com/), and [Alcove](https://tryalcove.com/). The app must be built entirely in **Swift + SwiftUI**, targeting **macOS 14 Sonoma+**, and must be **code-signed and notarized** for distribution via DMG.

---

## Tech Stack & Architecture

- **Language:** Swift 5.9+
- **UI Framework:** SwiftUI with AppKit interop where needed (NSWindow, NSPanel, NSScreen)
- **Build System:** Xcode project (`.xcodeproj`) with SPM dependencies
- **Minimum Target:** macOS 14.0 (Sonoma)
- **Architecture:** Universal Binary (arm64 + x86_64)
- **Distribution:** Notarized DMG installer
- **Data Storage:** Local only (UserDefaults + FileManager for settings, no cloud/server)

### Core Architecture Patterns
- **MVVM** with ObservableObject ViewModels
- **Combine** for reactive data streams (system events, media changes, notifications)
- Singleton **managers** for each system integration (MediaManager, BatteryManager, DisplayManager, etc.)
- **NSPanel** (non-activating, floating) for the island overlay window — must NOT steal focus from other apps
- **CGEventTap / NSEvent.addGlobalMonitorForEvents** for gesture detection

---

## Window & Rendering System

### Island Window
- Create a **borderless, transparent, always-on-top NSPanel** positioned at the top-center of the screen
- On **notched MacBooks**: position the island to visually replace/overlay the notch area
- On **non-notched Macs**: position at top-center with a pill-shaped black background
- The window must:
  - Float above all other windows (`.floating` level)
  - NOT appear in Mission Control or Exposé
  - NOT steal keyboard focus or become key window
  - NOT show in the Dock
  - Be visible on all Spaces/Desktops
  - Support **multiple displays** (show on the active display or primary display — user configurable)

### Island States & Animations
The island has **4 visual states** with fluid SwiftUI animations between them:

1. **Compact (Idle):** Small pill shape (~200×36pt) showing a minimal icon or nothing. This is the resting state.
2. **Compact Leading/Trailing:** Slightly expanded pill showing a small live indicator on one or both sides (e.g., music playing indicator on left, timer on right).
3. **Expanded:** Medium expansion (~360×80pt) showing a HUD — triggered by system events (volume change, brightness change, now playing change, etc.).
4. **Full Expanded:** Large expansion (~400×200pt+) showing detailed content — triggered by user click/hover/swipe on the island.

All transitions must use **spring animations** with matching curves to iOS Dynamic Island (`.spring(response: 0.35, dampingFraction: 0.75)`). Content inside must **morphologically transition** — elements should appear to grow from the pill rather than pop in.

---

## Feature Modules (HUDs & Widgets)

Each feature module is a self-contained SwiftUI view that can render in both **expanded** and **compact** states.

### 1. Now Playing / Media Controls (DynaMusic)

**Trigger:** Any media starts/stops/changes track via `MRMediaRemoteRegisterForNowPlayingNotifications` or MediaPlayer framework.

**Compact State:**
- Show album art thumbnail (circular, clipped) + artist/song name scrolling marquee
- Animated sound bars (3-bar equalizer animation) when playing

**Expanded State (on click/hover):**
- Full album artwork with rounded corners
- Song title, artist name, album name
- Playback progress bar (scrubbable)
- Play/Pause, Previous, Next, Shuffle, Repeat controls
- Volume slider
- Waveform / spectrogram visualization (animated, using Accelerate framework for FFT on audio if possible, or simulated)
- AirPlay output selector icon

**Supported Sources:**
- Apple Music
- Spotify (via `NSDistributedNotificationCenter` for Spotify notifications)
- YouTube Music (browser — via Now Playing system integration)
- Any app that publishes Now Playing info via MediaRemote

**Gestures:**
- Swipe left/right on compact state → skip track
- Click → expand to full controls
- Swipe down on expanded → collapse

---

### 2. System HUDs — Volume, Brightness, Keyboard Backlight (DynaKeys)

**Trigger:** Intercept and REPLACE the default macOS volume/brightness/keyboard backlight HUDs.

**Implementation:**
- Use `CGEventTap` to detect hardware key presses for volume/brightness/keyboard backlight
- Suppress the default macOS OSD (via `NSEvent` interception or by presenting the custom HUD fast enough)
- Alternatively, monitor `NSDistributedNotificationCenter` for system volume/brightness change notifications

**Compact State:**
- Icon (speaker/sun/keyboard) + slim progress bar inside the pill

**Expanded State:**
- Larger icon + percentage label + slider control
- Volume: show mute state, output device name (e.g., "MacBook Pro Speakers", "AirPods Pro")
- Brightness: show display name for multi-monitor setups
- Keyboard backlight: show current level

**Behavior:**
- Auto-show on system change, auto-dismiss after 1.5s of inactivity
- Smooth interpolation animation on the progress bar
- Overshoot animation when hitting 0% or 100%
- Mute icon state change with haptic-like visual bounce

---

### 3. Battery & Power (DynaPower)

**Trigger:** Battery level changes, charging state changes, low battery warnings.

**Compact State:**
- Battery icon with fill level + percentage text

**Expanded State:**
- Battery icon with detailed fill animation
- Percentage, time remaining estimate, power source (Battery/AC)
- Charging indicator with animated lightning bolt
- "Optimized Battery Charging" status if enabled
- Low battery warning (red pulse animation at ≤20%)

**Implementation:**
- Use `IOKit` (`IOPSCopyPowerSourcesInfo`) for real-time battery data
- Register for `NSNotification` power source change events

---

### 4. Connectivity Notifications (DynaConnect)

**Trigger:** Bluetooth device connects/disconnects, Wi-Fi changes, AirPods detected.

**Compact State:**
- Device icon (AirPods, headphones, speaker, etc.) + device name

**Expanded State:**
- Device icon + name + battery levels for each component (Left, Right, Case for AirPods)
- Connection animation (device icon morphs in with a connected line)
- Disconnect animation (icon fades with a broken link visual)

**Implementation:**
- `IOBluetooth` framework for Bluetooth device monitoring
- `CoreWLAN` / `SystemConfiguration` for Wi-Fi changes
- Battery info for AirPods via `IOBluetooth` private APIs or `IOKit`

---

### 5. Calendar & Schedule (DynaGlance)

**Trigger:** User clicks to expand, or auto-show before upcoming events (configurable: 5/10/15 min before).

**Compact State:**
- Small calendar icon + next event name + countdown ("in 12 min")

**Expanded State:**
- Today's date and day
- List of upcoming events for the day with color-coded calendar dots
- Event title, time, location
- "Join" button for video call links (Zoom, Meet, Teams — detect URL in event notes/location)
- Weather condition icon for empty time slots (optional)

**Implementation:**
- `EventKit` framework with proper permission request
- Support Apple Calendar, and any calendar synced via macOS Calendar
- Midnight refresh for next day's events
- Click on event → open in Calendar app or open join link

---

### 6. Weather (DynaWeather)

**Trigger:** Shown alongside calendar in expanded view, or as a standalone widget.

**Compact State:**
- Temperature + condition icon (☀️ 72°)

**Expanded State:**
- Current temperature, condition, high/low
- Hourly forecast (horizontal scroll, next 6 hours)
- Location name

**Implementation:**
- `WeatherKit` (requires Apple Developer Program) or `CoreLocation` + free weather API fallback
- Cache weather data, refresh every 30 minutes

---

### 7. Focus / Do Not Disturb Indicator

**Trigger:** Focus mode changes.

**Compact State:**
- Moon/focus icon + focus name ("Do Not Disturb", "Work", etc.)

**Implementation:**
- Monitor `NSDistributedNotificationCenter` for focus/DND state changes
- Show brief notification when focus mode activates/deactivates

---

### 8. Notification Mirroring

**Trigger:** macOS notifications from user-selected apps.

**Expanded State:**
- App icon + notification title + body text
- Action buttons if the notification has actions
- Swipe to dismiss

**Implementation:**
- Use `UNUserNotificationCenter` or accessibility APIs to read notifications
- User must grant Notification access in System Settings
- Configurable per-app: which apps' notifications appear in the island

---

### 9. File Drop Zone (DynaDrop)

**Trigger:** User drags a file over the island area.

**Behavior:**
- Island expands to show a drop zone with icons for:
  - AirDrop
  - iCloud Drive
  - Custom folder shortcuts
  - Quick conversion options (e.g., image format conversion, MP3 extraction)
- Drag and drop the file onto a target to perform the action
- Show progress indicator during transfer/conversion

**Implementation:**
- `NSPasteboardItem` / `NSDraggingDestination` on the island window
- `AVFoundation` for media conversion
- `NSWorkspace` for AirDrop integration

---

### 10. Lock Screen Widget

**Trigger:** Screen locks.

**Behavior:**
- When the screen is locked (screensaver / lock screen), show a widget overlay with:
  - Clock / time
  - Now Playing controls
  - Battery status
  - Next calendar event
- Fade in/out with the lock screen

**Implementation:**
- Detect screen lock via `NSDistributedNotificationCenter` (`com.apple.screenIsLocked` / `com.apple.screenIsUnlocked`)
- Present a full-screen overlay window on lock

---

## Gesture System

All gestures are detected on the island window:

| Gesture | Action |
|---|---|
| **Click** on compact island | Expand to show detailed view of active module |
| **Hover** over compact island | Show "quick peek" — slightly expand with summary |
| **Swipe Left/Right** on compact | Cycle through active modules (music, battery, etc.) |
| **Swipe Left/Right** on Now Playing | Skip track forward/backward |
| **Swipe Down** on expanded | Collapse back to compact |
| **Swipe Up** on compact | Expand to full view |
| **Long press** | Open settings for the current module |
| **Drag file over** | Activate DynaDrop zone |

**Implementation:**
- `NSPanGestureRecognizer`, `NSClickGestureRecognizer`, `NSPressGestureRecognizer`
- Swipe detection with velocity threshold to distinguish intentional swipes from hover drift
- All gestures must have configurable sensitivity in Settings

---

## Settings / Preferences Window

A proper macOS Settings window (using `Settings` scene in SwiftUI) with these sections:

### General
- Launch at login (toggle) — use `SMAppService` for modern login item registration
- Menu bar icon visibility (toggle)
- Island position: Auto (notch-aware) / Center / Custom offset
- Active display: Primary / Active (follows mouse) / Specific display
- Show on all Spaces (toggle)
- Animation speed: Normal / Reduced (for accessibility)

### Modules
Toggle each module on/off individually:
- Now Playing
- Volume HUD
- Brightness HUD
- Keyboard Backlight HUD
- Battery
- Connectivity
- Calendar
- Weather
- Focus
- Notifications
- DynaDrop

### Now Playing
- Show album art (toggle)
- Spectrogram style: Bars / Wave / Off
- Swipe to skip tracks (toggle)
- Supported apps (checkboxes)

### Notifications
- Per-app toggle for which apps show notifications in the island
- Notification display duration

### Calendar
- Calendar accounts to show (checkboxes)
- Pre-event notification time (5/10/15/30 min)
- Show weather in calendar (toggle)

### Appearance
- Island corner radius (slider)
- Island background: Black / Dark Blur / Custom Color
- Text color: White / Auto
- HUD animation overshoot (toggle)
- Compact island opacity when idle (slider, 0-100%)

### Advanced
- Accessibility: larger text mode
- Reset all settings
- Export/import settings
- Debug: show island bounds overlay

---

## Menu Bar Integration

- Show a **menu bar icon** (optional, toggleable) with a dropdown containing:
  - Current status summary (playing song, battery %, etc.)
  - Quick toggles for each module
  - "Settings..." menu item
  - "Quit DynamicIsland" menu item

---

## Performance Requirements

- **CPU usage:** < 2% idle, < 5% during animations
- **Memory:** < 50MB baseline
- **Energy Impact:** "Low" in Activity Monitor — critical for a background utility
- Use `CADisplayLink` or `TimelineView` for animations, NOT `Timer`
- Debounce rapid system events (e.g., holding volume key) to prevent animation stutter
- Lazy load modules — only initialize managers for enabled modules
- Release system event listeners when modules are disabled

---

## Code Signing, Notarization & DMG Packaging

### One-Command Build, Sign, Notarize & Package

Create a `scripts/build-and-release.sh` that does everything:

```bash
#!/bin/bash
# Usage: ./scripts/build-and-release.sh
# Requires: APPLE_ID, APP_SPECIFIC_PASSWORD, TEAM_ID, SIGNING_IDENTITY env vars
# or reads from .env file

set -euo pipefail

# --- Configuration (from env or .env file) ---
source .env 2>/dev/null || true
APP_NAME="DynamicIsland"
SCHEME="${APP_NAME}"
BUILD_DIR="build"
ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
APP_PATH="${BUILD_DIR}/${APP_NAME}.app"
DMG_PATH="${BUILD_DIR}/${APP_NAME}.dmg"
ENTITLEMENTS="DynamicIsland/DynamicIsland.entitlements"

# Required env vars
: "${APPLE_ID:?Set APPLE_ID in .env}"
: "${APP_SPECIFIC_PASSWORD:?Set APP_SPECIFIC_PASSWORD in .env}"
: "${TEAM_ID:?Set TEAM_ID in .env}"
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY in .env (e.g., 'Developer ID Application: Your Name (TEAMID)')}"

echo "==> Cleaning..."
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

echo "==> Archiving..."
xcodebuild archive \
  -project "${APP_NAME}.xcodeproj" \
  -scheme "${SCHEME}" \
  -configuration Release \
  -archivePath "${ARCHIVE_PATH}" \
  -destination "generic/platform=macOS" \
  SKIP_INSTALL=NO \
  BUILD_LIBRARY_FOR_DISTRIBUTION=YES

echo "==> Exporting archive..."
xcodebuild -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportOptionsPlist exportOptions.plist \
  -exportPath "${BUILD_DIR}"

echo "==> Code signing..."
codesign --deep --force --verify --verbose \
  --sign "${SIGNING_IDENTITY}" \
  --entitlements "${ENTITLEMENTS}" \
  --options runtime \
  "${APP_PATH}"

echo "==> Verifying signature..."
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
spctl --assess --type exec --verbose "${APP_PATH}"

echo "==> Creating DMG..."
hdiutil create -volname "${APP_NAME}" \
  -srcfolder "${APP_PATH}" \
  -ov -format UDZO \
  "${DMG_PATH}"

echo "==> Signing DMG..."
codesign --sign "${SIGNING_IDENTITY}" "${DMG_PATH}"

echo "==> Notarizing..."
xcrun notarytool submit "${DMG_PATH}" \
  --apple-id "${APPLE_ID}" \
  --password "${APP_SPECIFIC_PASSWORD}" \
  --team-id "${TEAM_ID}" \
  --wait

echo "==> Stapling notarization ticket..."
xcrun stapler staple "${DMG_PATH}"

echo "==> Verifying notarization..."
xcrun stapler validate "${DMG_PATH}"
spctl --assess --type open --context context:primary-signature --verbose "${DMG_PATH}"

echo ""
echo "✅ SUCCESS: ${DMG_PATH} is signed, notarized, and ready for distribution!"
echo "   File: $(du -h "${DMG_PATH}" | cut -f1) — ${DMG_PATH}"
```

### Required Files

**`.env`** (git-ignored):
```
APPLE_ID=your@email.com
APP_SPECIFIC_PASSWORD=xxxx-xxxx-xxxx-xxxx
TEAM_ID=XXXXXXXXXX
SIGNING_IDENTITY=Developer ID Application: Your Name (XXXXXXXXXX)
```

**`exportOptions.plist`:**
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$(TEAM_ID)</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
```

**`DynamicIsland.entitlements`:**
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.security.automation.apple-events</key>
    <true/>
    <key>com.apple.security.device.bluetooth</key>
    <true/>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.personal-information.calendars</key>
    <true/>
    <key>com.apple.security.personal-information.location</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
</dict>
</plist>
```

### Info.plist Requirements
```xml
<key>LSUIElement</key>
<true/>  <!-- Hide from Dock -->
<key>NSCalendarsUsageDescription</key>
<string>DynamicIsland needs calendar access to show upcoming events.</string>
<key>NSBluetoothAlwaysUsageDescription</key>
<string>DynamicIsland needs Bluetooth access to show connected device notifications.</string>
<key>NSLocationWhenInUseUsageDescription</key>
<string>DynamicIsland needs location access for weather information.</string>
<key>NSMicrophoneUsageDescription</key>
<string>DynamicIsland needs microphone access for audio visualization.</string>
```

---

## Project File Structure

```
DynamicIsland/
├── DynamicIsland.xcodeproj
├── DynamicIsland/
│   ├── App/
│   │   ├── DynamicIslandApp.swift          # @main, App lifecycle, menu bar
│   │   ├── AppDelegate.swift               # NSApplicationDelegate for AppKit integration
│   │   └── AppState.swift                  # Global app state ObservableObject
│   ├── Window/
│   │   ├── IslandWindowController.swift    # NSPanel setup, positioning, display management
│   │   ├── IslandWindow.swift              # Custom NSPanel subclass (non-activating, floating)
│   │   └── ScreenDetector.swift            # Notch detection, multi-display support
│   ├── Views/
│   │   ├── IslandContainerView.swift       # Root SwiftUI view — state machine for island states
│   │   ├── CompactView.swift               # Compact pill view
│   │   ├── ExpandedView.swift              # Expanded HUD view (routes to active module)
│   │   ├── FullExpandedView.swift          # Full detail view
│   │   └── Shared/
│   │       ├── PillShape.swift             # Smooth pill/capsule shape with dynamic corner radius
│   │       ├── MarqueeText.swift           # Auto-scrolling text for long strings
│   │       └── AnimatedGradient.swift      # Background gradient animations
│   ├── Modules/
│   │   ├── NowPlaying/
│   │   │   ├── NowPlayingManager.swift     # MediaRemote integration
│   │   │   ├── NowPlayingCompactView.swift
│   │   │   ├── NowPlayingExpandedView.swift
│   │   │   ├── SpectrogramView.swift       # Audio visualization
│   │   │   └── AlbumArtView.swift
│   │   ├── SystemHUD/
│   │   │   ├── VolumeManager.swift         # Volume monitoring & control
│   │   │   ├── BrightnessManager.swift     # Display brightness monitoring
│   │   │   ├── KeyboardBacklightManager.swift
│   │   │   ├── SystemHUDCompactView.swift
│   │   │   └── SystemHUDExpandedView.swift
│   │   ├── Battery/
│   │   │   ├── BatteryManager.swift        # IOKit power source monitoring
│   │   │   ├── BatteryCompactView.swift
│   │   │   └── BatteryExpandedView.swift
│   │   ├── Connectivity/
│   │   │   ├── BluetoothManager.swift      # IOBluetooth device monitoring
│   │   │   ├── WiFiManager.swift           # CoreWLAN monitoring
│   │   │   ├── ConnectivityCompactView.swift
│   │   │   └── ConnectivityExpandedView.swift
│   │   ├── Calendar/
│   │   │   ├── CalendarManager.swift       # EventKit integration
│   │   │   ├── CalendarCompactView.swift
│   │   │   └── CalendarExpandedView.swift
│   │   ├── Weather/
│   │   │   ├── WeatherManager.swift        # WeatherKit / API integration
│   │   │   ├── WeatherCompactView.swift
│   │   │   └── WeatherExpandedView.swift
│   │   ├── Focus/
│   │   │   ├── FocusManager.swift          # DND/Focus mode monitoring
│   │   │   └── FocusCompactView.swift
│   │   ├── Notifications/
│   │   │   ├── NotificationManager.swift   # Notification mirroring
│   │   │   ├── NotificationCompactView.swift
│   │   │   └── NotificationExpandedView.swift
│   │   └── FileDrop/
│   │       ├── FileDropManager.swift       # Drag & drop handling
│   │       └── FileDropView.swift
│   ├── Gestures/
│   │   ├── GestureHandler.swift            # Unified gesture recognition
│   │   └── SwipeDetector.swift             # Swipe direction & velocity detection
│   ├── Settings/
│   │   ├── SettingsView.swift              # Main settings window
│   │   ├── GeneralSettingsView.swift
│   │   ├── ModuleSettingsView.swift
│   │   ├── AppearanceSettingsView.swift
│   │   └── AdvancedSettingsView.swift
│   ├── Utilities/
│   │   ├── Permissions.swift               # Permission request helpers
│   │   ├── LaunchAtLogin.swift             # SMAppService wrapper
│   │   └── Constants.swift                 # App-wide constants
│   ├── Resources/
│   │   ├── Assets.xcassets                 # App icon, SF Symbols overrides
│   │   └── DynamicIsland.entitlements
│   └── Info.plist
├── scripts/
│   └── build-and-release.sh
├── exportOptions.plist
├── .env                                     # Git-ignored, signing credentials
├── .gitignore
└── README.md
```

---

## Critical Implementation Details

### 1. Non-Activating Window (MOST IMPORTANT)
```swift
class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = false  // We DO want mouse events for clicks/gestures
        self.hidesOnDeactivate = false
        self.isMovableByWindowBackground = false
    }
}
```

### 2. Notch Detection
```swift
func hasNotch(screen: NSScreen) -> Bool {
    guard let topLeft = screen.auxiliaryTopLeftArea,
          let topRight = screen.auxiliaryTopRightArea else {
        return false
    }
    // If there are auxiliary areas, the screen has a notch
    return true
}
```

### 3. MediaRemote (Now Playing)
Use the private `MediaRemote.framework` via dynamic loading:
```swift
// Load MediaRemote framework dynamically
let bundle = CFBundleCreate(kCFAllocatorDefault,
    "/System/Library/PrivateFrameworks/MediaRemote.framework" as CFString)
// Register for now playing notifications
MRMediaRemoteRegisterForNowPlayingNotifications(DispatchQueue.main)
// Get now playing info
MRMediaRemoteGetNowPlayingInfo(DispatchQueue.main) { info in ... }
```

### 4. Volume/Brightness Interception
For replacing system HUDs, use `CoreAudio` for volume and `IOKit` for brightness:
```swift
// Volume monitoring
AudioObjectAddPropertyListener(kAudioObjectSystemObject, &volumeAddress, volumeCallback, nil)

// Brightness monitoring
IODisplaySetFloatParameter(service, 0, kIODisplayBrightnessKey, newBrightness)
```

### 5. Suppress Default macOS OSD
To prevent the default volume/brightness OSD from showing, the app should display its own HUD fast enough or use known techniques:
- Present the custom HUD immediately on key event detection
- The system OSD may still appear underneath — hiding it requires creating a transparent overlay at the OSD's known position, or using the `OSDUIHelper` approach

---

## Animation Specifications

| Animation | Duration | Curve | Details |
|---|---|---|---|
| Compact → Expanded | 0.35s | Spring (response: 0.35, damping: 0.75) | Width/height grow, content fades in at 60% of animation |
| Expanded → Compact | 0.3s | Spring (response: 0.3, damping: 0.8) | Content fades out first, then size shrinks |
| Expanded → Full | 0.4s | Spring (response: 0.4, damping: 0.7) | Content morphs, additional rows slide down |
| HUD appear | 0.25s | easeOut | Fade + scale from center |
| HUD dismiss | 0.2s | easeIn | Fade + slight scale down |
| Progress bar update | 0.15s | easeInOut | Smooth interpolation |
| Content swap (module cycle) | 0.2s | easeInOut | Crossfade between module views |
| Overshoot bounce | 0.5s | Spring (response: 0.3, damping: 0.5) | Elastic bounce when hitting 0%/100% |

---

## Privacy & Permissions

On first launch, request permissions in this order (with clear explanations):
1. **Accessibility** — needed for gesture detection and system event monitoring
2. **Calendar** — for DynaGlance
3. **Bluetooth** — for DynaConnect
4. **Location** — for Weather
5. **Notifications** — for notification mirroring
6. **Microphone** (optional) — for audio visualization spectrogram

Show a **welcome/onboarding window** on first launch that walks through permissions with a progress indicator.

---

## Edge Cases to Handle

- Multiple displays: island should work correctly on each display independently
- Full-screen apps: island should appear above full-screen apps (configurable)
- Screen recording: island should be excludable from screen recordings via `window.sharingType = .none`
- Hot corners: island should not interfere with macOS hot corners
- Stage Manager: proper behavior when Stage Manager is enabled
- Clamshell mode: handle external display without built-in display
- Rapid system events: debounce volume/brightness key holds to prevent animation stutter
- App crash recovery: save state and restore on relaunch
- Memory pressure: release non-visible module resources under memory pressure
- Right-to-left languages: mirror swipe directions and text alignment

---

## Testing Checklist

Before release, verify:
- [ ] Island appears correctly on notched MacBook
- [ ] Island appears correctly on non-notched Mac / external display
- [ ] Island does NOT steal focus from any app
- [ ] Island does NOT appear in Mission Control
- [ ] Island does NOT appear in Cmd+Tab
- [ ] Volume/Brightness HUDs appear and auto-dismiss
- [ ] Now Playing shows correct info from Apple Music
- [ ] Now Playing shows correct info from Spotify
- [ ] Swipe gestures work for track skip
- [ ] Battery status updates in real-time
- [ ] Bluetooth device connection/disconnection notifications work
- [ ] Calendar events load and display correctly
- [ ] Settings window opens and all toggles persist
- [ ] Launch at login works
- [ ] App survives sleep/wake cycles
- [ ] App works on macOS 14 and macOS 15
- [ ] DMG installs cleanly
- [ ] Signed DMG passes Gatekeeper (no security warnings)
- [ ] CPU < 2% at idle
- [ ] Memory < 50MB baseline

---

## Summary

Build a polished, production-ready macOS Dynamic Island app with these priorities:
1. **Rock-solid window management** — non-activating, always-on-top, notch-aware
2. **Buttery smooth animations** — spring-based, morphological, 60fps
3. **Comprehensive system integration** — media, volume, brightness, battery, Bluetooth, calendar, weather
4. **Intuitive gesture system** — swipe, click, hover, drag-and-drop
5. **Full customizability** — every module toggleable, appearance tweakable
6. **One-command distribution** — `./scripts/build-and-release.sh` produces a signed, notarized DMG
