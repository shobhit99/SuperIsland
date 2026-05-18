import Foundation

struct NowPlayingSnapshot {
    let providerID: String
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let elapsedTime: TimeInterval
    let playbackRate: Double
    let isPlaying: Bool
    let sourceName: String
    let bundleIdentifier: String
    let albumArtist: String
    let artworkURL: String?
    let trackIdentifier: String
    let isLocalFile: Bool
    let browserTabURL: String
    let capturedAt: Date
}

enum NowPlayingProviderStatus: Equatable {
    case idle
    case checking(String)
    case playing(String)
    case paused(String)
    case stale(String)
    case browserDisabled
    case permissionNeeded(String)
    case unavailable(String)

    var title: String {
        switch self {
        case .idle:
            return "Nothing is playing"
        case .checking(let source):
            return "Checking \(source)"
        case .playing(let source):
            return source
        case .paused(let source):
            return "\(source) paused"
        case .stale(let source):
            return "\(source) last played"
        case .browserDisabled:
            return "Browser detection is off"
        case .permissionNeeded(let source):
            return "\(source) needs permission"
        case .unavailable(let source):
            return "\(source) unavailable"
        }
    }

    var subtitle: String {
        switch self {
        case .idle:
            return "Start playback to pin controls here."
        case .checking:
            return "Looking for active media."
        case .playing:
            return "Playback controls are ready."
        case .paused:
            return "Resume playback when you are ready."
        case .stale:
            return "The last known track is kept here briefly."
        case .browserDisabled:
            return "Enable browser media detection for Chrome playback."
        case .permissionNeeded:
            return "Allow automation access and browser JavaScript from Apple Events."
        case .unavailable:
            return "Open the app and start playback, then try again."
        }
    }
}

struct NowPlayingBrowserTarget: Identifiable, Equatable {
    let id: String
    let displayName: String
    let applicationName: String
    let processName: String
}

enum NowPlayingProviderError: Error {
    case unsupported
}

@MainActor
protocol NowPlayingProvider {
    var id: String { get }
    var displayName: String { get }
    var requiresPermission: Bool { get }
    func currentSnapshot() async -> NowPlayingSnapshot?
    func playPause() async throws
    func nextTrack() async throws
    func previousTrack() async throws
}

@MainActor
struct NowPlayingScriptProvider: NowPlayingProvider {
    let id: String
    let displayName: String
    let requiresPermission: Bool
    let currentSnapshotHandler: () async -> NowPlayingSnapshot?
    let playPauseHandler: () async throws -> Void
    let nextTrackHandler: () async throws -> Void
    let previousTrackHandler: () async throws -> Void

    init(
        id: String,
        displayName: String,
        requiresPermission: Bool,
        currentSnapshot: @escaping () async -> NowPlayingSnapshot?,
        playPause: @escaping () async throws -> Void = { throw NowPlayingProviderError.unsupported },
        nextTrack: @escaping () async throws -> Void = { throw NowPlayingProviderError.unsupported },
        previousTrack: @escaping () async throws -> Void = { throw NowPlayingProviderError.unsupported }
    ) {
        self.id = id
        self.displayName = displayName
        self.requiresPermission = requiresPermission
        self.currentSnapshotHandler = currentSnapshot
        self.playPauseHandler = playPause
        self.nextTrackHandler = nextTrack
        self.previousTrackHandler = previousTrack
    }

    func currentSnapshot() async -> NowPlayingSnapshot? {
        await currentSnapshotHandler()
    }

    func playPause() async throws {
        try await playPauseHandler()
    }

    func nextTrack() async throws {
        try await nextTrackHandler()
    }

    func previousTrack() async throws {
        try await previousTrackHandler()
    }
}
