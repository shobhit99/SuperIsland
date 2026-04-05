import AppKit
import Combine

// MARK: - MediaRemote Function Types
private typealias MRMediaRemoteRegisterForNowPlayingNotificationsFunction = @convention(c) (DispatchQueue) -> Void
private typealias MRMediaRemoteGetNowPlayingInfoFunction = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
private typealias MRMediaRemoteGetNowPlayingApplicationIsPlayingFunction = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
private typealias MRMediaRemoteSendCommandFunction = @convention(c) (UInt32, UnsafeMutableRawPointer?) -> Bool
private typealias MRMediaRemoteSetElapsedTimeFunction = @convention(c) (Double) -> Void

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
    @Published var albumArtColor: NSColor?
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
    private var setElapsedTimeFunc: MRMediaRemoteSetElapsedTimeFunction?

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
    private var currentBundleIdentifier: String = ""
    private var lastPlaybackUpdateDate: Date = .distantPast
    private var recentTrackChangeDate: Date = .distantPast
    private var adapterProcess: Process?
    private var adapterPipeHandler: JSONLinesPipeHandler?
    private var adapterStreamTask: Task<Void, Never>?
    private var adapterDidDeliverUpdate = false
    private let appleScriptQueue = DispatchQueue(label: "com.workview.SuperIsland.applescript", qos: .userInitiated)

    private init() {
        loadMediaRemote()
        registerForNotifications()
        Task { [weak self] in
            await self?.startMediaRemoteAdapterObserver()
        }
        fetchNowPlayingInfo()
        observeSpotify()
        observeAlbumArtColor()

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

        if let sym = dlsym(handle, "MRMediaRemoteSetElapsedTime") {
            setElapsedTimeFunc = unsafeBitCast(sym, to: MRMediaRemoteSetElapsedTimeFunction.self)
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

    private func observeAlbumArtColor() {
        $albumArt
            .removeDuplicates { $0?.tiffRepresentation == $1?.tiffRepresentation }
            .sink { [weak self] image in
                guard let self else { return }
                guard let image else {
                    self.albumArtColor = nil
                    return
                }
                image.averageColor { color in
                    guard let color else { return }
                    let rgb = color.usingColorSpace(.sRGB) ?? color
                    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                    rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
                    self.albumArtColor = NSColor(
                        hue: h,
                        saturation: min(max(s * 1.15, 0.55), 1.0),
                        brightness: min(max(b * 1.18, 0.72), 1.0),
                        alpha: a
                    )
                }
            }
            .store(in: &cancellables)
    }

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
                self.currentBundleIdentifier = ""
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

    // MARK: - MediaRemote Adapter

    private func startMediaRemoteAdapterObserver() async {
        guard adapterProcess == nil else { return }
        guard let resources = mediaRemoteAdapterResources() else {
            print("[NowPlaying] MediaRemote adapter resources not found")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [resources.scriptURL.path, resources.frameworkURL.path, "stream"]

        let pipeHandler = JSONLinesPipeHandler()
        process.standardOutput = await pipeHandler.getPipe()

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.adapterProcess = nil
                self?.adapterPipeHandler = nil
                self?.adapterStreamTask = nil
                self?.adapterDidDeliverUpdate = false
            }
        }

        adapterProcess = process
        adapterPipeHandler = pipeHandler

        do {
            try process.run()
            adapterStreamTask = Task { [weak self] in
                await self?.processAdapterJSONStream()
            }
        } catch {
            print("[NowPlaying] Failed to launch MediaRemote adapter: \(error)")
            adapterProcess = nil
            adapterPipeHandler = nil
        }
    }

    private func processAdapterJSONStream() async {
        guard let pipeHandler = adapterPipeHandler else { return }

        await pipeHandler.readJSONLines(as: NowPlayingUpdate.self) { [weak self] update in
            await self?.handleAdapterUpdate(update)
        }
    }

    private func handleAdapterUpdate(_ update: NowPlayingUpdate) async {
        adapterDidDeliverUpdate = true

        let payload = update.payload
        let diff = update.diff ?? false
        let previousElapsedTime = elapsedTime
        let previousPlaybackRate = playbackRate
        let previousPlaybackUpdateDate = lastPlaybackUpdateDate
        let bundleIdentifier = payload.parentApplicationBundleIdentifier ?? payload.bundleIdentifier ?? ""
        let resolvedTitle = payload.title ?? (diff ? title : "")
        let resolvedArtist = payload.artist ?? (diff ? artist : "")
        let resolvedAlbum = payload.album ?? (diff ? album : "")
        let resolvedDuration = payload.duration ?? (diff ? duration : 0)
        let resolvedPlaybackRate = payload.playbackRate ?? (diff ? playbackRate : 1.0)
        let resolvedIsPlaying = payload.playing ?? (diff ? isPlaying : false)
        let resolvedSourceName = sourceName(forBundleIdentifier: bundleIdentifier)
        let previousTrackSignature = trackSignature(
            title: title,
            artist: artist,
            album: album,
            bundleIdentifier: currentBundleIdentifier
        )
        let incomingTrackSignature = trackSignature(
            title: resolvedTitle,
            artist: resolvedArtist,
            album: resolvedAlbum,
            bundleIdentifier: bundleIdentifier
        )
        let trackChanged = !resolvedTitle.isEmpty && incomingTrackSignature != previousTrackSignature
        let resolvedUpdateDate: Date

        if let dateString = payload.timestamp,
           let date = ISO8601DateFormatter().date(from: dateString) {
            resolvedUpdateDate = date
        } else if diff {
            resolvedUpdateDate = previousPlaybackUpdateDate
        } else {
            resolvedUpdateDate = Date()
        }

        let resolvedElapsedTime: TimeInterval

        if let rawElapsedTime = payload.elapsedTime {
            resolvedElapsedTime = clampElapsedTime(rawElapsedTime, duration: resolvedDuration)
        } else if trackChanged {
            resolvedElapsedTime = 0
        } else if diff {
            if payload.playing == false {
                let delta = max(0, Date().timeIntervalSince(previousPlaybackUpdateDate))
                resolvedElapsedTime = clampElapsedTime(
                    previousElapsedTime + (previousPlaybackRate * delta),
                    duration: resolvedDuration
                )
            } else {
                resolvedElapsedTime = clampElapsedTime(previousElapsedTime, duration: resolvedDuration)
            }
        } else {
            resolvedElapsedTime = 0
        }

        mediaRemoteActive = !resolvedTitle.isEmpty || !bundleIdentifier.isEmpty
        currentBundleIdentifier = bundleIdentifier
        lastPlaybackUpdateDate = resolvedUpdateDate
        title = resolvedTitle
        artist = resolvedArtist
        album = resolvedAlbum
        duration = resolvedDuration
        playbackRate = resolvedPlaybackRate
        isPlaying = resolvedIsPlaying
        sourceName = resolvedSourceName

        if trackChanged {
            recentTrackChangeDate = Date()
        }

        let shouldResetSuspiciousElapsedTime =
            Date().timeIntervalSince(recentTrackChangeDate) < 1.5 &&
            resolvedElapsedTime > 3 &&
            resolvedDuration > 0 &&
            resolvedElapsedTime < resolvedDuration

        elapsedTime = shouldResetSuspiciousElapsedTime ? 0 : resolvedElapsedTime

        if isChromeBundleIdentifier(bundleIdentifier) {
            if !resolvedIsPlaying && !currentChromeTabURL.isEmpty {
                lastPausedChromeTabURL = currentChromeTabURL
            }
        } else {
            currentChromeTabURL = ""
            lastPausedChromeTabURL = ""
        }

        if let artworkDataString = payload.artworkData,
           let artworkData = Data(base64Encoded: artworkDataString.trimmingCharacters(in: .whitespacesAndNewlines)),
           let image = NSImage(data: artworkData) {
            albumArt = image
        } else if resolvedTitle.isEmpty {
            albumArt = nil
        }

        if !resolvedTitle.isEmpty, resolvedTitle != lastDetectedTitle {
            lastDetectedTitle = resolvedTitle
            AppState.shared.setActiveModule(.nowPlaying)
        } else if resolvedTitle.isEmpty {
            lastDetectedTitle = ""
        }

        updatePlaybackTimer()
    }

    private func mediaRemoteAdapterResources() -> (scriptURL: URL, frameworkURL: URL)? {
        if let resourceURL = Bundle.main.resourceURL {
            let adapterDirectory = resourceURL.appendingPathComponent("MediaRemoteAdapter", isDirectory: true)
            let scriptURL = adapterDirectory.appendingPathComponent("mediaremote-adapter.pl")
            let frameworkURL = adapterDirectory.appendingPathComponent("MediaRemoteAdapter.framework")

            if FileManager.default.fileExists(atPath: scriptURL.path),
               FileManager.default.fileExists(atPath: frameworkURL.path) {
                return (scriptURL, frameworkURL)
            }
        }

        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let adapterDirectory = sourceRoot.appendingPathComponent("Resources/MediaRemoteAdapter", isDirectory: true)
        let scriptURL = adapterDirectory.appendingPathComponent("mediaremote-adapter.pl")
        let frameworkURL = adapterDirectory.appendingPathComponent("MediaRemoteAdapter.framework")

        guard FileManager.default.fileExists(atPath: scriptURL.path),
              FileManager.default.fileExists(atPath: frameworkURL.path) else {
            return nil
        }

        return (scriptURL, frameworkURL)
    }

    // MARK: - AppleScript Fallback

    private func refreshPreferredSource() {
        guard !adapterDidDeliverUpdate else { return }
        let currentSource = sourceName

        appleScriptQueue.async { [weak self] in
            guard let self else { return }

            if self.refreshCurrentSourceIfNeeded(sourceName: currentSource) {
                DispatchQueue.main.async { self.mediaRemoteActive = false }
                return
            }

            if self.fetchSpotifyViaAppleScript() {
                DispatchQueue.main.async { self.mediaRemoteActive = false }
                return
            }

            if self.fetchMusicViaAppleScript() {
                DispatchQueue.main.async { self.mediaRemoteActive = false }
                return
            }

            if self.fetchChromeViaAppleScript(allowPausedFallback: false) {
                DispatchQueue.main.async { self.mediaRemoteActive = false }
                return
            }

            DispatchQueue.main.async { self.fetchNowPlayingInfo() }
        }
    }

    nonisolated private func refreshCurrentSourceIfNeeded(sourceName: String) -> Bool {
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

    private var shouldUseMediaRemoteControls: Bool {
        mediaRemoteActive || (adapterDidDeliverUpdate && !currentBundleIdentifier.isEmpty)
    }

    nonisolated private func fetchSpotifyViaAppleScript() -> Bool {
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
            if trackTitle != self?.lastDetectedTitle {
                self?.lastDetectedTitle = trackTitle
                AppState.shared.setActiveModule(.nowPlaying)
            }
        }
        fetchSpotifyArtwork()
        return true
    }

    nonisolated private func fetchSpotifyArtwork() {
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

    nonisolated private func fetchMusicViaAppleScript() -> Bool {
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

    nonisolated private func fetchChromeViaAppleScript(allowPausedFallback: Bool = true) -> Bool {
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

    nonisolated private func parseYouTubeTitle(_ rawTitle: String) -> (title: String, artist: String) {
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

    nonisolated private func fetchYouTubeThumbnail(from urlString: String) {
        // Extract video ID and fetch thumbnail
        guard let videoID = extractYouTubeVideoID(from: urlString) else { return }

        let thumbnailURL = "https://img.youtube.com/vi/\(videoID)/mqdefault.jpg"
        fetchRemoteArtwork(from: thumbnailURL)
    }

    nonisolated private func fetchRemoteArtwork(from urlString: String) {
        guard let url = URL(string: urlString) else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                self?.albumArt = image
            }
        }.resume()
    }

    nonisolated private func extractYouTubeVideoID(from urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        return components.queryItems?.first(where: { $0.name == "v" })?.value
    }

    // MARK: - AppleScript Runner

    nonisolated private func runAppleScript(_ source: String) -> String? {
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

        if shouldUseMediaRemoteControls {
            _ = sendCommandFunc?(shouldPlay ? kMRPlay : kMRPause, nil)
            refreshPlaybackStateAfterControlAction()
            return
        }

        if isChromePlaybackSource {
            _ = controlChromePlayback(shouldPlay: shouldPlay)
            refreshPlaybackStateAfterControlAction(preferChromeRefresh: true)
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
        if shouldUseMediaRemoteControls {
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
        if shouldUseMediaRemoteControls {
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

    func seek(to time: TimeInterval) {
        let clampedTime = max(0, min(time, duration))
        elapsedTime = clampedTime
        updatePlaybackTimer()

        if shouldUseMediaRemoteControls {
            setElapsedTimeFunc?(clampedTime)
            refreshPlaybackStateAfterControlAction()
            return
        }

        switch sourceName {
        case "Spotify":
            _ = runAppleScript("tell application \"Spotify\" to set player position to \(clampedTime)")
        case "Apple Music":
            _ = runAppleScript("tell application \"Music\" to set player position to \(clampedTime)")
        default:
            break
        }
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

    nonisolated private func chromeSourceName(for url: String) -> String {
        if url.contains("music.youtube.com") { return "YouTube Music" }
        if url.contains("youtube.com") { return "YouTube" }
        if url.contains("soundcloud.com") { return "SoundCloud" }
        if url.contains("spotify.com") { return "Spotify Web" }
        return "Google Chrome"
    }

    private func sourceName(forBundleIdentifier bundleIdentifier: String) -> String {
        switch bundleIdentifier {
        case "com.apple.Music":
            return "Apple Music"
        case "com.spotify.client":
            return "Spotify"
        case "com.google.Chrome":
            return "Google Chrome"
        case "com.google.Chrome.canary":
            return "Google Chrome Canary"
        case "com.apple.Safari":
            return "Safari"
        case "com.microsoft.edgemac":
            return "Microsoft Edge"
        default:
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
               let bundle = Bundle(url: appURL),
               let appName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
               !appName.isEmpty {
                return appName
            }
            return bundleIdentifier
        }
    }

    var sourceAppIcon: NSImage? {
        guard !currentBundleIdentifier.isEmpty,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: currentBundleIdentifier) else {
            return nil
        }

        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        icon.size = NSSize(width: 24, height: 24)
        return icon
    }

    private func trackSignature(title: String, artist: String, album: String, bundleIdentifier: String) -> String {
        [bundleIdentifier, title, artist, album]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "||")
    }

    private func clampElapsedTime(_ elapsedTime: TimeInterval, duration: TimeInterval) -> TimeInterval {
        let normalizedElapsedTime = max(0, elapsedTime)
        guard duration > 0 else {
            return normalizedElapsedTime
        }
        return min(normalizedElapsedTime, duration)
    }

    private func isChromeBundleIdentifier(_ bundleIdentifier: String) -> Bool {
        bundleIdentifier == "com.google.Chrome" || bundleIdentifier == "com.google.Chrome.canary"
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
        adapterStreamTask?.cancel()
        if let adapterPipeHandler {
            Task {
                await adapterPipeHandler.close()
            }
        }
        if let adapterProcess, adapterProcess.isRunning {
            adapterProcess.terminate()
            adapterProcess.waitUntilExit()
        }
        if let handle {
            dlclose(handle)
        }
    }
}

private struct NowPlayingUpdate: Decodable {
    let payload: NowPlayingPayload
    let diff: Bool?
}

private struct NowPlayingPayload: Decodable {
    let title: String?
    let artist: String?
    let album: String?
    let duration: Double?
    let elapsedTime: Double?
    let artworkData: String?
    let timestamp: String?
    let playbackRate: Double?
    let playing: Bool?
    let parentApplicationBundleIdentifier: String?
    let bundleIdentifier: String?
}

private actor JSONLinesPipeHandler {
    private let pipe = Pipe()
    private lazy var fileHandle = pipe.fileHandleForReading
    private var buffer = ""

    func getPipe() -> Pipe {
        pipe
    }

    func readJSONLines<T: Decodable>(as type: T.Type, onLine: @escaping (T) async -> Void) async {
        do {
            while true {
                let data = try await readData()
                guard !data.isEmpty else { break }

                if let chunk = String(data: data, encoding: .utf8) {
                    buffer.append(chunk)

                    while let range = buffer.range(of: "\n") {
                        let line = String(buffer[..<range.lowerBound])
                        buffer = String(buffer[range.upperBound...])

                        guard !line.isEmpty, let lineData = line.data(using: .utf8) else { continue }

                        do {
                            let decoded = try JSONDecoder().decode(T.self, from: lineData)
                            await onLine(decoded)
                        } catch {
                            continue
                        }
                    }
                }
            }
        } catch {
            print("[NowPlaying] Error reading MediaRemote adapter stream: \(error)")
        }
    }

    private func readData() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            fileHandle.readabilityHandler = { handle in
                let data = handle.availableData
                handle.readabilityHandler = nil
                continuation.resume(returning: data)
            }
        }
    }

    func close() async {
        do {
            fileHandle.readabilityHandler = nil
            try fileHandle.close()
            try pipe.fileHandleForWriting.close()
        } catch {
            print("[NowPlaying] Error closing MediaRemote adapter pipe: \(error)")
        }
    }
}
