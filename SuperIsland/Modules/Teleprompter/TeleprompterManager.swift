import Foundation
import SwiftUI

@MainActor
final class TeleprompterManager: ObservableObject {
    static let shared = TeleprompterManager()

    // MARK: - Script

    @Published var scriptText: String {
        didSet { UserDefaults.standard.set(scriptText, forKey: "teleprompter.script") }
    }

    // MARK: - Playback state

    @Published var isPlaying: Bool = false

    /// Non-nil while the 3-2-1 countdown is running.
    @Published private(set) var countdownValue: Int? = nil

    /// True after a reset — next play() will show the countdown.
    private var pendingCountdown: Bool = true

    /// Incremented on reset so views can snap their scroll offset back to 0.
    @Published private(set) var resetToken: UUID = UUID()

    /// Monotonically-increasing cumulative pixel nudge applied by scroll-wheel input.
    /// The view subtracts the previously-consumed value to get the delta for each tick.
    @Published private(set) var scrollNudge: CGFloat = 0

    // MARK: - Style settings (persisted)

    /// Pixels per second of scroll speed.
    @Published var scrollSpeed: Double {
        didSet { UserDefaults.standard.set(scrollSpeed, forKey: "teleprompter.scrollSpeed") }
    }

    /// Font size in points.
    @Published var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: "teleprompter.fontSize") }
    }

    /// 0 = leading, 1 = center, 2 = trailing
    @Published var textAlignmentIndex: Int {
        didSet { UserDefaults.standard.set(textAlignmentIndex, forKey: "teleprompter.alignment") }
    }

    var textAlignment: TextAlignment {
        switch textAlignmentIndex {
        case 0: return .leading
        case 2: return .trailing
        default: return .center
        }
    }

    // MARK: - Private

    private var countdownTimer: Timer?

    private init() {
        self.scriptText   = UserDefaults.standard.string(forKey: "teleprompter.script") ?? ""
        let speed         = UserDefaults.standard.double(forKey: "teleprompter.scrollSpeed")
        self.scrollSpeed  = speed > 0 ? speed : 7.0
        let size          = UserDefaults.standard.double(forKey: "teleprompter.fontSize")
        self.fontSize     = size > 0 ? size : 22.0
        let align         = UserDefaults.standard.object(forKey: "teleprompter.alignment") as? Int
        self.textAlignmentIndex = align ?? 1
    }

    // MARK: - Computed

    var hasScript: Bool {
        !scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isCountingDown: Bool { countdownValue != nil }

    // MARK: - Script

    func setScript(_ text: String) {
        scriptText = text
        reset()
    }

    // MARK: - Playback

    func play() {
        guard hasScript else { return }
        if pendingCountdown {
            pendingCountdown = false
            startCountdown()
        } else {
            isPlaying = true
        }
    }

    func pause() {
        cancelCountdown()
        isPlaying = false
    }

    func reset() {
        cancelCountdown()
        isPlaying = false
        pendingCountdown = true
        scrollNudge = 0
        resetToken = UUID()
    }

    func togglePlayPause() {
        if isPlaying || isCountingDown { pause() } else { play() }
    }

    /// Seek the scroll position by `delta` pixels. Positive = forward (toward end).
    /// Additive to ongoing auto-scroll — does NOT pause playback.
    func nudgeOffset(by delta: CGFloat) {
        guard hasScript else { return }
        scrollNudge += delta
    }

    // MARK: - Countdown

    private func startCountdown() {
        cancelCountdown()
        countdownValue = 3
        var remaining = 3
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                remaining -= 1
                if remaining > 0 {
                    self.countdownValue = remaining
                } else {
                    self.cancelCountdown()
                    self.isPlaying = true
                }
            }
        }
    }

    private func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownValue = nil
    }
}
