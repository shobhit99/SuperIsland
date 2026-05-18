import SwiftUI

struct SpectrogramView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var manager = NowPlayingManager.shared

    let barCount: Int = 32
    @State private var barHeights: [CGFloat] = []
    @State private var animationTimer: Timer?

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(barColor(for: index))
                    .frame(width: 3)
                    .scaleEffect(y: barHeights.indices.contains(index) ? barHeights[index] : 0.1, anchor: .bottom)
            }
        }
        .onAppear {
            barHeights = (0..<barCount).map { _ in CGFloat.random(in: 0.1...0.3) }
            if manager.isPlaying && !appState.shouldReduceAnimations {
                animateBars()
            }
        }
        .onDisappear {
            stopAnimating()
        }
        .onChange(of: manager.isPlaying) { _, playing in
            if playing && !appState.shouldReduceAnimations {
                animateBars()
            } else {
                quietBars()
            }
        }
        .onChange(of: appState.shouldReduceAnimations) { _, reduced in
            if reduced {
                quietBars()
            } else if manager.isPlaying {
                animateBars()
            }
        }
    }

    private func barColor(for index: Int) -> Color {
        let ratio = Double(index) / Double(barCount)
        return Color(
            hue: 0.55 + ratio * 0.15,
            saturation: 0.8,
            brightness: 0.9
        )
    }

    private func animateBars() {
        guard animationTimer == nil else { return }
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            Task { @MainActor in
                guard manager.isPlaying, !appState.shouldReduceAnimations else {
                    stopAnimating()
                    return
                }
                withAnimation(.easeInOut(duration: 0.2)) {
                    barHeights = (0..<barCount).map { index in
                        // Simulate frequency spectrum: lower bars tend higher
                        let base = 1.0 - (Double(index) / Double(barCount)) * 0.5
                        return CGFloat(base * Double.random(in: 0.2...1.0))
                    }
                }
            }
        }
    }

    private func quietBars() {
        stopAnimating()
        withAnimation(.easeOut(duration: 0.5)) {
            barHeights = (0..<barCount).map { _ in CGFloat(0.1) }
        }
    }

    private func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
    }
}
