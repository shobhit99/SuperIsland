import AppKit
import SwiftUI

struct NowPlayingCompactView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var manager = NowPlayingManager.shared

    var body: some View {
        HStack(spacing: 8) {
            albumHint

            if appState.usesWideCompactLayout && !manager.title.isEmpty {
                Text(manager.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
            playbackHint
        }
    }

    private var compactArtSize: CGFloat {
        appState.usesWideCompactLayout ? 22 : 24
    }

    @ViewBuilder
    private var albumHint: some View {
        if let art = manager.albumArt {
            Image(nsImage: art)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: compactArtSize, height: compactArtSize)
                .clipShape(Circle())
        } else {
            Image(systemName: "music.note")
                .font(.system(size: appState.usesWideCompactLayout ? 11 : 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
                .frame(width: compactArtSize, height: compactArtSize)
                .background(.white.opacity(0.08), in: Circle())
        }
    }

    @ViewBuilder
    private var playbackHint: some View {
        NowPlayingPlaybackCompactButton()
    }
}

// MARK: - Equalizer Bars Animation

final class CompactAudioSpectrumView: NSView {
    private var barLayers: [CAShapeLayer] = []
    private var barScales: [CGFloat] = []
    private var animationTimer: Timer?
    private var barColor: NSColor = .white

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupBars()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setupBars()
    }

    deinit {
        animationTimer?.invalidate()
    }

    private func setupBars() {
        let barWidth: CGFloat = 2
        let barCount = 4
        let spacing: CGFloat = barWidth
        let totalWidth = CGFloat(barCount) * (barWidth + spacing)
        let totalHeight: CGFloat = 14

        frame.size = CGSize(width: totalWidth, height: totalHeight)

        for index in 0..<barCount {
            let xPosition = CGFloat(index) * (barWidth + spacing)
            let barLayer = CAShapeLayer()
            barLayer.frame = CGRect(x: xPosition, y: 0, width: barWidth, height: totalHeight)
            barLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            barLayer.position = CGPoint(x: xPosition + (barWidth / 2), y: totalHeight / 2)
            barLayer.fillColor = barColor.cgColor
            barLayer.backgroundColor = barColor.cgColor
            barLayer.allowsGroupOpacity = false
            barLayer.masksToBounds = true
            barLayer.path = NSBezierPath(
                roundedRect: CGRect(x: 0, y: 0, width: barWidth, height: totalHeight),
                xRadius: barWidth / 2,
                yRadius: barWidth / 2
            ).cgPath

            barLayers.append(barLayer)
            barScales.append(0.35)
            layer?.addSublayer(barLayer)
        }
    }

    func updateBarColor(_ color: NSColor) {
        guard color != barColor else { return }
        barColor = color
        for barLayer in barLayers {
            barLayer.fillColor = color.cgColor
            barLayer.backgroundColor = color.cgColor
        }
    }

    func setPlaying(_ isPlaying: Bool) {
        if isPlaying {
            startAnimating()
        } else {
            stopAnimating()
        }
    }

    private func startAnimating() {
        guard animationTimer == nil else { return }

        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.updateBars()
        }
        updateBars()
    }

    private func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
        resetBars()
    }

    private func updateBars() {
        for (index, barLayer) in barLayers.enumerated() {
            let currentScale = barScales[index]
            let targetScale = CGFloat.random(in: 0.35...1.0)
            barScales[index] = targetScale

            let animation = CABasicAnimation(keyPath: "transform.scale.y")
            animation.fromValue = currentScale
            animation.toValue = targetScale
            animation.duration = 0.3
            animation.autoreverses = true
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false

            if #available(macOS 13.0, *) {
                animation.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 24, preferred: 24)
            }

            barLayer.add(animation, forKey: "scaleY")
        }
    }

    private func resetBars() {
        for (index, barLayer) in barLayers.enumerated() {
            barLayer.removeAllAnimations()
            barLayer.transform = CATransform3DMakeScale(1, 0.35, 1)
            barScales[index] = 0.35
        }
    }
}

struct EqualizerBarsView: NSViewRepresentable {
    let isPlaying: Bool
    var barColor: NSColor = .white

    func makeNSView(context: Context) -> CompactAudioSpectrumView {
        let spectrumView = CompactAudioSpectrumView()
        spectrumView.updateBarColor(barColor)
        spectrumView.setPlaying(isPlaying)
        return spectrumView
    }

    func updateNSView(_ nsView: CompactAudioSpectrumView, context: Context) {
        nsView.updateBarColor(barColor)
        nsView.setPlaying(isPlaying)
    }
}

struct NowPlayingPlaybackCompactButton: View {
    @ObservedObject private var manager = NowPlayingManager.shared
    @State private var isHovering = false

    var body: some View {
        Button {
            AppState.shared.beginCompactControlInteraction()
            manager.togglePlayPause()
        } label: {
            Group {
                if manager.isPlaying {
                    if isHovering {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white.opacity(0.95))
                            .frame(width: 18, height: 18)
                    } else {
                        EqualizerBarsView(
                            isPlaying: true,
                            barColor: manager.albumArtColor ?? .white
                        )
                        .frame(width: 20, height: 16)
                    }
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.9))
                        .frame(width: 18, height: 18)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverPointer()
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
