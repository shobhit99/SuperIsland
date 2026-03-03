import SwiftUI

struct SpectrogramView: View {
    @ObservedObject private var manager = NowPlayingManager.shared

    let barCount: Int = 32
    @State private var barHeights: [CGFloat] = []

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
            if manager.isPlaying {
                animateBars()
            }
        }
        .onChange(of: manager.isPlaying) { _, playing in
            if playing {
                animateBars()
            } else {
                quietBars()
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
        Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { timer in
            guard manager.isPlaying else {
                timer.invalidate()
                return
            }
            withAnimation(.easeInOut(duration: 0.15)) {
                barHeights = (0..<barCount).map { index in
                    // Simulate frequency spectrum: lower bars tend higher
                    let base = 1.0 - (Double(index) / Double(barCount)) * 0.5
                    return CGFloat(base * Double.random(in: 0.2...1.0))
                }
            }
        }
    }

    private func quietBars() {
        withAnimation(.easeOut(duration: 0.5)) {
            barHeights = (0..<barCount).map { _ in CGFloat(0.1) }
        }
    }
}
