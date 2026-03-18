import SwiftUI
import AVFoundation
import AVKit

struct MascotRendererView: View {
    let size: Double
    let extensionID: String?
    var expressionOverride: String?

    @ObservedObject private var manager = MascotManager.shared

    var body: some View {
        Group {
            if shouldHideMascot {
                Color.clear
                    .frame(width: size, height: size)
            } else if manager.isLoading && manager.currentLoopVideoURL == nil {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .frame(width: size, height: size)
            } else if let loopURL = manager.currentLoopVideoURL {
                MascotVideoPlayer(url: loopURL)
                    .frame(width: size, height: size)
                    .id(loopURL)
            } else if let thumbnailURL = manager.thumbnailURL {
                AsyncImage(url: thumbnailURL) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Color.clear
                }
                .frame(width: size, height: size)
            } else {
                Color.clear
                    .frame(width: size, height: size)
            }
        }
        .onChange(of: expressionOverride) { _, newValue in
            if let newValue {
                manager.setExpression(newValue)
            }
        }
    }

    private var shouldHideMascot: Bool {
        extensionID == "com.workview.pomodoro" && !manager.showInPomodoro
    }
}

// MARK: - AVPlayer-based HEVC Video Player with Alpha (loop only)

struct MascotVideoPlayer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> MascotVideoNSView {
        let view = MascotVideoNSView()
        view.playLoop(url: url)
        return view
    }

    func updateNSView(_ nsView: MascotVideoNSView, context: Context) {
        if nsView.currentURL != url {
            nsView.playLoop(url: url)
        }
    }
}

final class MascotVideoNSView: NSView {
    private var player: AVQueuePlayer?
    private var playerLayer: AVPlayerLayer?
    private var looper: AVPlayerLooper?

    private(set) var currentURL: URL?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        playerLayer?.frame = bounds
    }

    func playLoop(url: URL) {
        guard url != currentURL else { return }
        cleanup()
        currentURL = url

        let item = AVPlayerItem(url: url)
        let queuePlayer = AVQueuePlayer(playerItem: item)
        looper = AVPlayerLooper(player: queuePlayer, templateItem: item)

        queuePlayer.isMuted = true

        let layer = AVPlayerLayer(player: queuePlayer)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = .clear
        layer.isOpaque = false
        layer.frame = bounds

        if layer.responds(to: NSSelectorFromString("setPixelBufferAttributes:")) {
            layer.pixelBufferAttributes = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        }

        playerLayer?.removeFromSuperlayer()
        playerLayer = layer
        player = queuePlayer
        self.layer?.addSublayer(layer)

        queuePlayer.play()
    }

    private func cleanup() {
        looper?.disableLooping()
        looper = nil
        player?.pause()
        player?.removeAllItems()
        player = nil
        currentURL = nil
    }

    deinit {
        looper?.disableLooping()
        player?.pause()
    }
}
