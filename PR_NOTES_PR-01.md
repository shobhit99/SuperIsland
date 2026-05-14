# PR-01 Notes

Title: Reduce idle energy usage with central module refresh scheduling

Branch: `perf/energy-and-refresh-scheduler`

Linked issues:
- #67 Energy consumption on MacBook Air is very poor
- #68 Poor power management
- #69 Using Significant Energy

Summary:
- Adds a central refresh scheduler for built-in modules and extensions.
- Adds Normal, Smart, and Low Power profiles in Settings -> General -> Power.
- Pauses or slows non-essential refresh while modules are hidden, disabled, collapsed, or inactive.
- Adds optional Low Power suggestions for battery transitions and sustained refresh activity.
- Adds scheduler diagnostics in Settings -> Advanced.
- Adds timer tolerance, lifecycle cleanup, and duplicate state suppression across the highest-frequency managers.
- Guards extension refresh intervals and suspends inactive extension timers in Smart and Low Power conditions.

Validation:
- `git diff --check` passed.
- Direct Swift typecheck of app sources passed with the package-backed analytics source excluded because package resolution depends on generated project setup.
- `xcodebuild -version` reported Xcode 26.5.
- `xcodegen generate` could not run because `xcodegen` is unavailable locally.
- `xcodebuild -project SuperIsland.xcodeproj -scheme SuperIsland -configuration Debug build` could not run because the project file is generated and is not present without XcodeGen.

Screenshots needed:
- Settings -> General -> Power section.
- Settings -> Advanced -> Energy Diagnostics section with scheduled jobs visible.

Risk notes:
- Refresh cadence changes can affect perceived freshness for notifications, extensions, and Now Playing fallback updates.
- Calendar still has existing Swift concurrency warnings around EventKit values used off the main queue.
- Weather still has existing macOS 26 deprecation warnings for reverse geocoding APIs.
- Manual idle-energy verification in Activity Monitor or Instruments is still needed on a real Mac session.

PR status:
- Branch is prepared locally.
- PR was not opened locally because the GitHub CLI is unavailable.
