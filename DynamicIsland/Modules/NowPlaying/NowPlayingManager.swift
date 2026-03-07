import AppKit
import Combine

// MARK: - MediaRemote Function Types
private typealias MRMediaRemoteRegisterForNowPlayingNotificationsFunction = @convention(c) (DispatchQueue) -> Void
private typealias MRMediaRemoteGetNowPlayingInfoFunction = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
private typealias MRMediaRemoteGetNowPlayingApplicationIsPlayingFunction = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
private typealias MRMediaRemoteSendCommandFunction = @convention(c) (UInt32, UnsafeMutableRawPointer?) -> Bool

// MediaRemote command constants
private let kMRPlay: UInt32 = 0
private let kMRPause: UInt32 = 1
private let kMRTogglePlayPause: UInt32 = 2
private let kMRStop: UInt32 = 3
private let kMRNextTrack: UInt32 = 4
private let kMRPreviousTrack: UInt32 = 5

// MediaRemote info keys
private let kMRMediaRemoteNowPlayingInfoTitle = "kMRMediaRemoteNowPlayingInfoTitle"
private let kMRMediaRemoteNowPlayingInfoArtist = "kMRMediaRemoteNowPlayingInfoArtist"
private let kMRMediaRemoteNowPlayingInfoAlbum = "kMRMediaRemoteNowPlayingInfoAlbum"
private let kMRMediaRemoteNowPlayingInfoArtworkData = "kMRMediaRemoteNowPlayingInfoArtworkData"
private let kMRMediaRemoteNowPlayingInfoDuration = "kMRMediaRemoteNowPlayingInfoDuration"
private let kMRMediaRemoteNowPlayingInfoElapsedTime = "kMRMediaRemoteNowPlayingInfoElapsedTime"
private let kMRMediaRemoteNowPlayingInfoPlaybackRate = "kMRMediaRemoteNowPlayingInfoPlaybackRate"

@MainActor
final class NowPlayingManager: ObservableObject {
    static let shared = NowPlayingManager()

    @Published var title: String = ""
    @Published var artist: String = ""
    @Published var album: String = ""
    @Published var albumArt: NSImage?
    @Published var isPlaying: Bool = false
    @Published var duration: TimeInterval = 0
    @Published var elapsedTime: TimeInterval = 0
    @Published var playbackRate: Double = 0
    @Published var sourceName: String = "" // "Spotify", "Apple Music", "Chrome", etc.

    private var handle: UnsafeMutableRawPointer?
    private var registerFunc: MRMediaRemoteRegisterForNowPlayingNotificationsFunction?
    private var getNowPlayingInfoFunc: MRMediaRemoteGetNowPlayingInfoFunction?
    private var getIsPlayingFunc: MRMediaRemoteGetNowPlayingApplicationIsPlayingFunction?
    private var sendCommandFunc: MRMediaRemoteSendCommandFunction?

    private var playbackTimer: Timer?
    private var pollTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // Track whether MediaRemote is providing data
    private var mediaRemoteActive = false
    // Track last detected title to avoid re-activating the module on every poll
    private var lastDetectedTitle: String = ""
    // Track the most recent Chrome media tab and the last one paused by our controls.
    private var currentChromeTabURL: String = ""
    private var lastPausedChromeTabURL: String = ""

    private init() {
        loadMediaRemote()
        registerForNotifications()
        fetchNowPlayingInfo()
        observeSpotify()

        // Trigger first AppleScript check on main thread to ensure
        // the macOS automation permission dialog appears
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.refreshPreferredSource()
            self?.startPolling()
        }
    }

    // MARK: - Polling

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refreshPreferredSource()
        }
    }

    // MARK: - MediaRemote Loading

    private func loadMediaRemote() {
        handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
        guard handle != nil else {
            print("[NowPlaying] Failed to load MediaRemote framework")
            return
        }

        if let sym = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications") {
            registerFunc = unsafeBitCast(sym, to: MRMediaRemoteRegisterForNowPlayingNotificationsFunction.self)
        }

        if let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
            getNowPlayingInfoFunc = unsafeBitCast(sym, to: MRMediaRemoteGetNowPlayingInfoFunction.self)
        }

        if let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") {
            getIsPlayingFunc = unsafeBitCast(sym, to: MRMediaRemoteGetNowPlayingApplicationIsPlayingFunction.self)
        }

        if let sym = dlsym(handle, "MRMediaRemoteSendCommand") {
            sendCommandFunc = unsafeBitCast(sym, to: MRMediaRemoteSendCommandFunction.self)
        }
    }

    // MARK: - Registration

    private func registerForNotifications() {
        registerFunc?(DispatchQueue.main)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(nowPlayingInfoDidChange),
            name: NSNotification.Name("kMRMediaRemoteNowPlayingInfoDidChangeNotification"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(nowPlayingApplicationIsPlayingDidChange),
            name: NSNotification.Name("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(nowPlayingApplicationDidChange),
            name: NSNotification.Name("kMRMediaRemoteNowPlayingApplicationDidChangeNotification"),
            object: nil
        )
    }

    // MARK: - Spotify Distributed Notifications

    private func observeSpotify() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(spotifyStateChanged),
            name: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil
        )
    }

    @objc private func spotifyStateChanged(_ notification: Notification) {
        refreshPreferredSource()
    }

    // MARK: - Notification Handlers

    @objc private func nowPlayingInfoDidChange() {
        refreshPreferredSource()
    }

    @objc private func nowPlayingApplicationIsPlayingDidChange() {
        refreshPreferredSource()
    }

    @objc private func nowPlayingApplicationDidChange() {
        refreshPreferredSource()
    }

    // MARK: - MediaRemote Data Fetching

    func fetchNowPlayingInfo() {
        getNowPlayingInfoFunc?(DispatchQueue.main) { [weak self] info in
            guard let self else { return }

            let newTitle = info[kMRMediaRemoteNowPlayingInfoTitle] as? String ?? ""
            let newPlaybackRate = info[kMRMediaRemoteNowPlayingInfoPlaybackRate] as? Double ?? 0

            if !newTitle.isEmpty, newPlaybackRate > 0 {
                self.mediaRemoteActive = true
                self.currentChromeTabURL = ""
                self.title = newTitle
                self.artist = info[kMRMediaRemoteNowPlayingInfoArtist] as? String ?? ""
                self.album = info[kMRMediaRemoteNowPlayingInfoAlbum] as? String ?? ""
                self.duration = info[kMRMediaRemoteNowPlayingInfoDuration] as? TimeInterval ?? 0
                self.elapsedTime = info[kMRMediaRemoteNowPlayingInfoElapsedTime] as? TimeInterval ?? 0
                self.playbackRate = newPlaybackRate
                self.isPlaying = true
                self.sourceName = "System Media"

                if let artworkData = info[kMRMediaRemoteNowPlayingInfoArtworkData] as? Data {
                    self.albumArt = NSImage(data: artworkData)
                }

                // Only activate module when track changes, not on every poll
                if newTitle != self.lastDetectedTitle {
                    self.lastDetectedTitle = newTitle
                    AppState.shared.setActiveModule(.nowPlaying)
                }
                self.updatePlaybackTimer()
            } else {
                self.mediaRemoteActive = false
            }
        }
    }

    private func fetchPlaybackState() {
        getIsPlayingFunc?(DispatchQueue.main) { [weak self] playing in
            self?.isPlaying = playing
            self?.updatePlaybackTimer()
        }
    }

    // MARK: - AppleScript Fallback

    private func refreshPreferredSource() {
        let work = { [weak self] in
            guard let self else { return }

            if self.refreshCurrentSourceIfNeeded() { return }

            if self.fetchSpotifyViaAppleScript() == true {
                self.mediaRemoteActive = false
                return
            }

            if self.fetchMusicViaAppleScript() == true {
                self.mediaRemoteActive = false
                return
            }

            if self.fetchChromeViaAppleScript(allowPausedFallback: false) == true {
                self.mediaRemoteActive = false
                return
            }

            self.fetchNowPlayingInfo()
        }

        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async { work() }
        }
    }

    private func refreshCurrentSourceIfNeeded() -> Bool {
        switch sourceName {
        case "Spotify":
            return fetchSpotifyViaAppleScript()
        case "Apple Music":
            return fetchMusicViaAppleScript()
        case "YouTube", "YouTube Music", "SoundCloud", "Spotify Web", "Google Chrome":
            return fetchChromeViaAppleScript(allowPausedFallback: false)
        default:
            return false
        }
    }

    private func fetchSpotifyViaAppleScript() -> Bool {
        let script = """
        tell application "System Events"
            if not (exists process "Spotify") then return "NOT_RUNNING"
        end tell
        tell application "Spotify"
            if player state is playing then
                set trackName to name of current track
                set trackArtist to artist of current track
                set trackAlbum to album of current track
                set trackDuration to duration of current track
                set trackPosition to player position
                return trackName & "||" & trackArtist & "||" & trackAlbum & "||" & (trackDuration / 1000) & "||" & trackPosition
            else
                return "NOT_PLAYING"
            end if
        end tell
        """

        guard let result = runAppleScript(script), result != "NOT_RUNNING", result != "NOT_PLAYING" else {
            return false
        }

        let parts = result.components(separatedBy: "||")
        guard parts.count >= 5 else { return false }

        let trackTitle = parts[0]
        DispatchQueue.main.async { [weak self] in
            self?.currentChromeTabURL = ""
            self?.title = trackTitle
            self?.artist = parts[1]
            self?.album = parts[2]
            self?.duration = TimeInterval(parts[3]) ?? 0
            self?.elapsedTime = TimeInterval(parts[4]) ?? 0
            self?.isPlaying = true
            self?.sourceName = "Spotify"
            self?.fetchSpotifyArtwork()
            if trackTitle != self?.lastDetectedTitle {
                self?.lastDetectedTitle = trackTitle
                AppState.shared.setActiveModule(.nowPlaying)
            }
        }
        return true
    }

    private func fetchSpotifyArtwork() {
        let script = """
        tell application "Spotify"
            return artwork url of current track
        end tell
        """
        guard let urlString = runAppleScript(script), let url = URL(string: urlString) else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                self?.albumArt = image
            }
        }.resume()
    }

    private func fetchMusicViaAppleScript() -> Bool {
        let script = """
        tell application "System Events"
            if not (exists process "Music") then return "NOT_RUNNING"
        end tell
        tell application "Music"
            if player state is playing then
                set trackName to name of current track
                set trackArtist to artist of current track
                set trackAlbum to album of current track
                set trackDuration to duration of current track
                set trackPosition to player position
                return trackName & "||" & trackArtist & "||" & trackAlbum & "||" & trackDuration & "||" & trackPosition
            else
                return "NOT_PLAYING"
            end if
        end tell
        """

        guard let result = runAppleScript(script), result != "NOT_RUNNING", result != "NOT_PLAYING" else {
            return false
        }

        let parts = result.components(separatedBy: "||")
        guard parts.count >= 5 else { return false }

        let trackTitle = parts[0]
        DispatchQueue.main.async { [weak self] in
            self?.currentChromeTabURL = ""
            self?.title = trackTitle
            self?.artist = parts[1]
            self?.album = parts[2]
            self?.duration = TimeInterval(parts[3]) ?? 0
            self?.elapsedTime = TimeInterval(parts[4]) ?? 0
            self?.isPlaying = true
            self?.sourceName = "Apple Music"
            if trackTitle != self?.lastDetectedTitle {
                self?.lastDetectedTitle = trackTitle
                AppState.shared.setActiveModule(.nowPlaying)
            }
        }
        return true
    }

    private func fetchChromeViaAppleScript(allowPausedFallback: Bool = true) -> Bool {
        let pausedReturn = allowPausedFallback
            ? "if pausedURL is not \"\" then return \"PAUSED_TAB||\" & pausedTitle & \"||\" & pausedURL & \"||\" & pausedInfo"
            : ""
        let script = """
        tell application "System Events"
            if not (exists process "Google Chrome") then return "NOT_RUNNING"
        end tell
        tell application "Google Chrome"
            set playingTitle to ""
            set playingURL to ""
            set playingInfo to ""
            set pausedTitle to ""
            set pausedURL to ""
            set pausedInfo to ""
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set mediaInfo to execute t javascript "
                            (function() {
                                var media = Array.from(document.querySelectorAll('video,audio'));
                                if (!media.length) return 'NO_MEDIA';
                                var active = media.find(function(item) { return !item.paused && !item.ended; });
                                var candidate = active || media.find(function(item) { return !item.ended; }) || media[0];
                                if (!candidate) return 'NO_MEDIA';
                                var metaImage = document.querySelector('meta[property=\"og:image\"], meta[name=\"twitter:image\"], link[rel=\"image_src\"]');
                                var thumbnail = candidate.poster || (metaImage ? (metaImage.content || metaImage.href || '') : '');
                                return (active ? 'PLAYING' : 'PAUSED') + '||' + candidate.currentTime + '||' + candidate.duration + '||' + thumbnail;
                            })();
                        "
                        if mediaInfo starts with "PLAYING||" then
                            set playingTitle to title of t
                            set playingURL to URL of t
                            set playingInfo to mediaInfo
                            exit repeat
                        else if mediaInfo starts with "PAUSED||" then
                            if pausedURL is "" then
                                set pausedTitle to title of t
                                set pausedURL to URL of t
                                set pausedInfo to mediaInfo
                            end if
                        end if
                    end try
                end repeat
                if playingURL is not "" then exit repeat
            end repeat
            if playingURL is not "" then return "PLAYING_TAB||" & playingTitle & "||" & playingURL & "||" & playingInfo
            \(pausedReturn)
            return "NOT_FOUND"
        end tell
        """

        guard let result = runAppleScript(script), result != "NOT_RUNNING", result != "NOT_FOUND" else {
            return false
        }

        let parts = result.components(separatedBy: "||")
        guard parts.count >= 5 else { return false }

        let rawTitle = parts[1]
        let url = parts[2]
        let playbackState = parts[3]
        let artworkURL = parts.count >= 7 ? parts[6] : ""

        var mediaCurrentTime: TimeInterval = 0
        var mediaDuration: TimeInterval = 0
        let mediaIsPlaying = playbackState == "PLAYING"

        mediaCurrentTime = TimeInterval(parts[4]) ?? 0
        if parts.count >= 6 {
            mediaDuration = TimeInterval(parts[5]) ?? 0
        }

        // Parse YouTube title format: "Song Name - Artist - YouTube"
        let parsed = parseYouTubeTitle(rawTitle)
        let chromeSourceName = chromeSourceName(for: url)

        DispatchQueue.main.async { [weak self] in
            self?.title = parsed.title
            self?.artist = parsed.artist
            self?.album = ""
            self?.isPlaying = mediaIsPlaying
            self?.elapsedTime = mediaCurrentTime
            self?.duration = mediaDuration
            self?.currentChromeTabURL = url
            self?.sourceName = chromeSourceName
            if parsed.title != self?.lastDetectedTitle {
                self?.lastDetectedTitle = parsed.title
                self?.albumArt = nil
                AppState.shared.setActiveModule(.nowPlaying)
            }
        }

        if !artworkURL.isEmpty {
            fetchRemoteArtwork(from: artworkURL)
        } else if url.contains("youtube.com") {
            fetchYouTubeThumbnail(from: url)
        }

        return true
    }

    // MARK: - YouTube Helpers

    private func parseYouTubeTitle(_ rawTitle: String) -> (title: String, artist: String) {
        // YouTube titles are typically: "Song Name - Artist - YouTube"
        // or "Song Name - YouTube"
        let cleaned = rawTitle
            .replacingOccurrences(of: " - YouTube Music", with: "")
            .replacingOccurrences(of: " - YouTube", with: "")
            .trimmingCharacters(in: .whitespaces)

        // Try to split on " - " to get artist and title
        let dashParts = cleaned.components(separatedBy: " - ")
        if dashParts.count >= 2 {
            // Could be "Artist - Song" or "Song - Artist"
            // YouTube Music usually does "Song - Artist"
            return (title: dashParts[0].trimmingCharacters(in: .whitespaces),
                    artist: dashParts[1...].joined(separator: " - ").trimmingCharacters(in: .whitespaces))
        }

        return (title: cleaned, artist: "")
    }

    private func fetchYouTubeThumbnail(from urlString: String) {
        // Extract video ID and fetch thumbnail
        guard let videoID = extractYouTubeVideoID(from: urlString) else { return }

        let thumbnailURL = "https://img.youtube.com/vi/\(videoID)/mqdefault.jpg"
        fetchRemoteArtwork(from: thumbnailURL)
    }

    private func fetchRemoteArtwork(from urlString: String) {
        guard let url = URL(string: urlString) else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                self?.albumArt = image
            }
        }.resume()
    }

    private func extractYouTubeVideoID(from urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        return components.queryItems?.first(where: { $0.name == "v" })?.value
    }

    // MARK: - AppleScript Runner

    private func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if let error {
            // Don't log "application not running" errors as they're expected
            let errorNum = error[NSAppleScript.errorNumber] as? Int ?? 0
            if errorNum != -600 && errorNum != -1728 {
                print("[NowPlaying] AppleScript error: \(error)")
            }
            return nil
        }
        return result.stringValue
    }

    // MARK: - Playback Timer

    private func updatePlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil

        guard isPlaying, duration > 0 else { return }

        playbackTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, self.isPlaying else { return }
            self.elapsedTime += 1.0
            if self.elapsedTime >= self.duration {
                self.elapsedTime = self.duration
                self.playbackTimer?.invalidate()
            }
        }
    }

    // MARK: - Playback Controls

    func togglePlayPause() {
        if sourceName == "Spotify", !isApplicationRunning("Spotify") {
            refreshPreferredSource()
            return
        }

        if sourceName == "Apple Music", !isApplicationRunning("Music") {
            refreshPreferredSource()
            return
        }

        let shouldPlay = !isPlaying

        // Immediately toggle local state for responsive UI
        isPlaying = shouldPlay
        updatePlaybackTimer()

        if isChromePlaybackSource {
            _ = controlChromePlayback(shouldPlay: shouldPlay)
            refreshPlaybackStateAfterControlAction(preferChromeRefresh: true)
            return
        }

        // Try MediaRemote first
        if mediaRemoteActive {
            _ = sendCommandFunc?(shouldPlay ? kMRPlay : kMRPause, nil)
            refreshPlaybackStateAfterControlAction()
            return
        }

        // Fallback to AppleScript
        switch sourceName {
        case "Spotify":
            _ = runAppleScript("tell application \"Spotify\" to \(shouldPlay ? "play" : "pause")")
        case "Apple Music":
            _ = runAppleScript("tell application \"Music\" to \(shouldPlay ? "play" : "pause")")
        default:
            _ = sendCommandFunc?(shouldPlay ? kMRPlay : kMRPause, nil)
        }

        refreshPlaybackStateAfterControlAction()
    }

    func nextTrack() {
        if mediaRemoteActive {
            _ = sendCommandFunc?(kMRNextTrack, nil)
            return
        }
        switch sourceName {
        case "Spotify":
            _ = runAppleScript("tell application \"Spotify\" to next track")
        case "Apple Music":
            _ = runAppleScript("tell application \"Music\" to next track")
        default:
            _ = sendCommandFunc?(kMRNextTrack, nil)
        }
    }

    func previousTrack() {
        if mediaRemoteActive {
            _ = sendCommandFunc?(kMRPreviousTrack, nil)
            return
        }
        switch sourceName {
        case "Spotify":
            _ = runAppleScript("tell application \"Spotify\" to previous track")
        case "Apple Music":
            _ = runAppleScript("tell application \"Music\" to previous track")
        default:
            _ = sendCommandFunc?(kMRPreviousTrack, nil)
        }
    }

    func skipTrack(forward: Bool) {
        if forward { nextTrack() } else { previousTrack() }
    }

    // MARK: - Helpers

    var formattedElapsedTime: String {
        formatTime(elapsedTime)
    }

    var formattedDuration: String {
        formatTime(duration)
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return elapsedTime / duration
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var isChromePlaybackSource: Bool {
        switch sourceName {
        case "YouTube", "YouTube Music", "SoundCloud", "Spotify Web", "Google Chrome":
            return true
        default:
            return !currentChromeTabURL.isEmpty && !lastPausedChromeTabURL.isEmpty
        }
    }

    private func refreshPlaybackStateAfterControlAction(preferChromeRefresh: Bool = false) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            if preferChromeRefresh {
                _ = self?.fetchChromeViaAppleScript()
                return
            }
            self?.refreshPreferredSource()
        }
    }

    private func controlChromePlayback(shouldPlay: Bool) -> Bool {
        let preferredURL = shouldPlay ? lastPausedChromeTabURL : currentChromeTabURL
        let js = chromeControlJavaScript(shouldPlay: shouldPlay)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedPreferredURL = escapeAppleScriptString(preferredURL)

        let script = """
        tell application "System Events"
            if not (exists process "Google Chrome") then return "NOT_RUNNING"
        end tell
        tell application "Google Chrome"
            set preferredURL to "\(escapedPreferredURL)"
            if preferredURL is not "" then
                repeat with w in windows
                    repeat with t in tabs of w
                        if (URL of t) is preferredURL then
                            try
                                set actionResult to execute t javascript "\(js)"
                                if actionResult is "OK" then return "OK||" & (URL of t)
                            end try
                        end if
                    end repeat
                end repeat
            end if
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set actionResult to execute t javascript "\(js)"
                        if actionResult is "OK" then return "OK||" & (URL of t)
                    end try
                end repeat
            end repeat
            return "NO_MEDIA"
        end tell
        """

        guard let result = runAppleScript(script), result.hasPrefix("OK||") else {
            return false
        }

        let actedURL = String(result.dropFirst(4))
        currentChromeTabURL = actedURL
        if shouldPlay {
            if lastPausedChromeTabURL == actedURL {
                lastPausedChromeTabURL = ""
            }
        } else {
            lastPausedChromeTabURL = actedURL
        }
        return true
    }

    private func chromeControlJavaScript(shouldPlay: Bool) -> String {
        if shouldPlay {
            return """
            (function() {
                var media = Array.from(document.querySelectorAll('video,audio'));
                if (!media.length) return 'NO_MEDIA';
                var target = media.find(function(item) { return item.paused && !item.ended; }) || media.find(function(item) { return !item.ended; }) || media[0];
                if (!target) return 'NO_MEDIA';
                try {
                    target.play();
                    return 'OK';
                } catch (error) {
                    return 'ERROR';
                }
            })();
            """
        }

        return """
        (function() {
            var media = Array.from(document.querySelectorAll('video,audio'));
            if (!media.length) return 'NO_MEDIA';
            var handled = false;
            media.forEach(function(item) {
                if (!item.paused && !item.ended) {
                    item.pause();
                    handled = true;
                }
            });
            return handled ? 'OK' : 'NO_MATCH';
        })();
        """
    }

    private func chromeSourceName(for url: String) -> String {
        if url.contains("music.youtube.com") { return "YouTube Music" }
        if url.contains("youtube.com") { return "YouTube" }
        if url.contains("soundcloud.com") { return "SoundCloud" }
        if url.contains("spotify.com") { return "Spotify Web" }
        return "Google Chrome"
    }

    private func escapeAppleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func isApplicationRunning(_ name: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            app.localizedName == name && !app.isTerminated
        }
    }

    deinit {
        playbackTimer?.invalidate()
        pollTimer?.invalidate()
        if let handle {
            dlclose(handle)
        }
    }
}
