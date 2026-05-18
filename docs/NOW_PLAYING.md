# Now Playing

The Now Playing module combines the system media feed with app-specific fallbacks for Apple Music and Spotify.

## Browser media detection

Browser media detection is off by default. When enabled in Settings -> Modules -> Now Playing, SuperIsland can use macOS Automation to inspect allowed browser tabs for active `video` and `audio` elements.

Supported browser targets:

- Google Chrome
- Google Chrome Canary

Browser detection requires:

- Automation permission for SuperIsland
- The browser running with media in an open tab
- JavaScript from Apple Events enabled in the browser

If detection is unavailable, the app keeps browser support explicit instead of showing a misleading playing state.

## Provider states

Now Playing distinguishes active playback, paused playback, stale last-known playback, missing permissions, and no detected media. A paused or recently known track can remain visible briefly so the home panel does not immediately collapse to an empty state.

## Controls

System media controls continue to use the existing system path. Apple Music and Spotify controls use their app automation support. Browser controls are only attempted for browser media that was detected through the opt-in browser path.
