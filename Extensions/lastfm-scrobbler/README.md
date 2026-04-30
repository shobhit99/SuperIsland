# Last.fm Scrobbler

Bundled SuperIsland extension that scrobbles the track currently playing on
your Mac to Last.fm.

## Files

- `manifest.json` - extension metadata, permissions, and capabilities
- `index.js` - scrobbling logic and island UI
- `settings.json` - settings rendered natively in SuperIsland Settings
- `icon.svg` - Last.fm icon shown in the extensions list and module picker

## Setup

1. Open **SuperIsland -> Settings -> Extensions -> Last.fm Scrobbler**.
2. Press **Log In to Last.fm** to launch the SuperCMD-hosted OAuth flow in your browser.
3. Approve access for SuperIsland once and you'll be redirected back to the app.

No API key or secret entry is required. SuperCMD brokers the Last.fm session
and the access token is stored locally in SuperIsland's extension storage.

## Runtime Behavior

- Requires the host app's `"media"` permission bridge to read now-playing
  metadata via `SuperIsland.system.getNowPlaying()`.
- Polls playback every second and counts only active listening time.
- Sends one `track.updateNowPlaying` per playback session when enabled.
- Scrobbles after Last.fm's threshold:
  - tracks over 30 seconds only
  - at half the track length or 240 seconds, whichever comes first
- Persists a retry queue locally and flushes in batches of up to 50 scrobbles.
- Uses a minimal compact notch surface plus compact and full expanded views.

## Notes

- The extension is bundled with the app through `project.yml`.
- It is also compatible with user-installed extensions in
  `~/Library/Application Support/SuperIsland/Extensions/`.
- Large artwork data URLs are not persisted to local storage to keep extension
  state lightweight across refreshes and restarts.
