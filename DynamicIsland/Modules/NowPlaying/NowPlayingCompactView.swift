import SwiftUI

struct NowPlayingCompactView: View {
    @ObservedObject private var manager = NowPlayingManager.shared

    var body: some View {
        HStack(spacing: 0) {
            albumHint
            Spacer(minLength: 0)
            playbackHint
        }
    }

    @ViewBuilder
    private var albumHint: some View {
        if let art = manager.albumArt {
            Image(nsImage: art)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 24, height: 24)
                .clipShape(Circle())
        } else {
            Image(systemName: "music.note")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
                .frame(width: 24, height: 24)
                .background(.white.opacity(0.08), in: Circle())
        }
    }

    @ViewBuilder
    private var playbackHint: some View {
        if manager.isPlaying {
            EqualizerBarsView()
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: "play.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white.opacity(0.9))
                .frame(width: 18, height: 18)
        }
    }
}

// MARK: - Equalizer Bars Animation

struct EqualizerBarsView: View {
    @State private var heights: [CGFloat] = [0.3, 0.6, 0.4]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(.white)
                    .frame(width: 3)
                    .scaleEffect(y: heights[index], anchor: .bottom)
            }
        }
        .onAppear {
            animate()
        }
    }

    private func animate() {
        withAnimation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true)) {
            heights = [0.8, 0.4, 0.9]
        }
        withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true).delay(0.1)) {
            heights[1] = 0.9
        }
        withAnimation(.easeInOut(duration: 0.35).repeatForever(autoreverses: true).delay(0.2)) {
            heights[2] = 0.6
        }
    }
}
