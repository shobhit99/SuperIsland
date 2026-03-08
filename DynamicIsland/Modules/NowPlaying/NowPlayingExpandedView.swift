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
                ProgressBar(
                    progress: manager.progress,
                    trackHeight: 3,
                    knobSize: 8
                ) { newProgress in
                    manager.seek(to: manager.duration * newProgress)
                }
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
                ProgressBar(
                    progress: manager.progress,
                    trackHeight: 4,
                    knobSize: 12
                ) { newProgress in
                    manager.seek(to: manager.duration * newProgress)
                }

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
            .padding(.top, 6)
        }
    }
}

// MARK: - Progress Bar

struct ProgressBar: View {
    let progress: Double
    var trackHeight: CGFloat = 4
    var knobSize: CGFloat = 10
    var onSeek: ((Double) -> Void)? = nil

    @State private var dragProgress: Double?
    @State private var isHovering = false

    var body: some View {
        GeometryReader { geometry in
            let displayedProgress = min(max(dragProgress ?? progress, 0), 1)
            let knobCenterX = min(
                max(CGFloat(displayedProgress) * geometry.size.width, knobSize / 2),
                max(knobSize / 2, geometry.size.width - (knobSize / 2))
            )
            let knobVisible = onSeek != nil && (isHovering || dragProgress != nil)
            let knobScale = (isHovering || dragProgress != nil) ? 1.08 : 1

            ZStack {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: trackHeight / 2)
                        .fill(.white.opacity(0.2))
                        .frame(height: trackHeight)

                    RoundedRectangle(cornerRadius: trackHeight / 2)
                        .fill(.white)
                        .frame(width: max(0, geometry.size.width * CGFloat(displayedProgress)), height: trackHeight)
                        .animation(Constants.progressBar, value: displayedProgress)

                    Circle()
                        .fill(.white)
                        .frame(width: knobSize, height: knobSize)
                        .scaleEffect(knobScale)
                        .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
                        .offset(x: knobCenterX - (knobSize / 2))
                        .opacity(knobVisible ? 1 : 0)
                        .animation(.easeOut(duration: 0.14), value: knobVisible)
                        .animation(.easeOut(duration: 0.14), value: knobScale)
                }
                .frame(height: knobSize)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard onSeek != nil, geometry.size.width > 0 else { return }
                        let nextProgress = min(max(value.location.x / geometry.size.width, 0), 1)
                        dragProgress = nextProgress
                    }
                    .onEnded { value in
                        guard let onSeek, geometry.size.width > 0 else { return }
                        let nextProgress = min(max(value.location.x / geometry.size.width, 0), 1)
                        dragProgress = nil
                        onSeek(nextProgress)
                    }
            )
        }
        .frame(height: max(knobSize, 16))
    }
}
