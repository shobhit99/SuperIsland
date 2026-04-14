import SwiftUI

struct TeleprompterCompactView: View {
    @ObservedObject private var manager = TeleprompterManager.shared

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "scroll")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(manager.isPlaying ? 0.9 : 0.45))
                .symbolEffect(.pulse, isActive: manager.isPlaying)

            Text(manager.hasScript ? (manager.isPlaying ? "Playing" : "Paused") : "No script")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(manager.hasScript ? 0.8 : 0.35))
                .lineLimit(1)
        }
    }
}
