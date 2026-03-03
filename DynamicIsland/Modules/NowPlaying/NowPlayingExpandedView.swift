import SwiftUI

struct NowPlayingExpandedView: View {
    @ObservedObject private var manager = NowPlayingManager.shared
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if appState.currentState == .fullExpanded {
                fullView
            } else {
                compactExpandedView
            }
        }
    }

    // MARK: - Compact Expanded (360x80)

    private var compactExpandedView: some View {
        HStack(spacing: 12) {
            // Album art
            AlbumArtView(image: manager.albumArt, size: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(manager.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text(manager.artist)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(1)

                // Progress bar
                ProgressBar(progress: manager.progress)
                    .frame(height: 3)
            }

            // Play/Pause button
            Button(action: { manager.togglePlayPause() }) {
                Image(systemName: manager.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Full Expanded (400x200+)

    private var fullView: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                AlbumArtView(image: manager.albumArt, size: 90)

                VStack(alignment: .leading, spacing: 4) {
                    Text(manager.title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(2)

                    Text(manager.artist)
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)

                    Text(manager.album)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                }

                Spacer()
            }

            // Progress bar with times
            VStack(spacing: 4) {
                ProgressBar(progress: manager.progress)
                    .frame(height: 4)

                HStack {
                    Text(manager.formattedElapsedTime)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                    Spacer()
                    Text(manager.formattedDuration)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                }
            }

            // Playback controls
            HStack(spacing: 32) {
                Button(action: { manager.previousTrack() }) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)

                Button(action: { manager.togglePlayPause() }) {
                    Image(systemName: manager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 36))
                }
                .buttonStyle(.plain)

                Button(action: { manager.nextTrack() }) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
            }
            .foregroundColor(.white)
            .offset(y: -4)
        }
    }
}

// MARK: - Progress Bar

struct ProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.white.opacity(0.2))

                RoundedRectangle(cornerRadius: 2)
                    .fill(.white)
                    .frame(width: max(0, geometry.size.width * CGFloat(min(progress, 1.0))))
                    .animation(Constants.progressBar, value: progress)
            }
        }
    }
}
