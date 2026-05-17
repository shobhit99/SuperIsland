# Energy behavior

SuperIsland uses a central refresh scheduler for recurring module and extension work. Managers register the work they need, the scheduler applies the current island state and power mode, and timers use tolerance so macOS can coalesce wakeups.

## Power modes

- Normal: keeps refresh behavior responsive.
- Smart: reduces background refresh while the island is collapsed and restores quickly when the user hovers, focuses, or expands the island.
- Low Power: slows non-essential refresh, reduces motion, and pauses inactive extension timers.

The setting is available in Settings -> General -> Power.
If macOS Low Power Mode is active, scheduler behavior follows the Low Power profile without changing the saved SuperIsland setting.

## Current scheduler coverage

- Weather refresh is cached and only scheduled while the weather module is visible.
- Calendar uses EventKit change notifications plus a low-frequency fallback refresh.
- Battery updates are event-driven where possible; history and consumer scans run through the scheduler.
- Connectivity uses Wi-Fi and Bluetooth events plus slower visible-only fallbacks.
- Now Playing keeps provider refresh conservative and only advances progress while visible.
- Notifications avoid one-second log polling and run lower-frequency scheduled scans.
- Extension refresh jobs are scheduler-backed, and inactive extension timers can be suspended by Smart, Low Power, or the background-refresh setting.

## Verification notes for PR-01

Before this change, several modules owned independent repeating timers, including one-second notification log scans, half-second extension refresh, and visible animation timers without lifecycle cleanup. After this change, recurring work is registered centrally, inactive work can pause, and diagnostics in Settings -> Advanced show active jobs, status, next fire time, and last run cost.

Suggested local checks:

```bash
xcodegen generate
xcodebuild -project SuperIsland.xcodeproj -scheme SuperIsland -configuration Debug build
git diff --check
```

Manual smoke checks:

- Launch SuperIsland, leave the island collapsed, and confirm Activity Monitor does not show persistent high CPU.
- Open Settings -> Advanced and confirm scheduler jobs are paused or scheduled as expected.
- Switch between Normal, Smart, and Low Power modes.
- Disable modules and confirm their scheduled work stops.
- Play media and confirm Now Playing remains responsive when visible.
