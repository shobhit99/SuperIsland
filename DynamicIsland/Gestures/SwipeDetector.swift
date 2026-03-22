import AppKit
import SwiftUI

struct SwipeDetector: ViewModifier {
    let onSwipe: (SwipeDirection) -> Void
    var minimumDistance: CGFloat = 20
    var velocityThreshold: CGFloat = 100

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: minimumDistance)
                .onEnded { value in
                    let horizontal = value.translation.width
                    let vertical = value.translation.height
                    let velocity = sqrt(
                        pow(value.velocity.width, 2) + pow(value.velocity.height, 2)
                    )

                    guard velocity > velocityThreshold else { return }

                    if abs(horizontal) > abs(vertical) {
                        onSwipe(horizontal > 0 ? .right : .left)
                    } else {
                        onSwipe(vertical > 0 ? .down : .up)
                    }
                }
        )
    }
}

extension View {
    func onSwipe(
        minimumDistance: CGFloat = 20,
        velocityThreshold: CGFloat = 100,
        perform action: @escaping (SwipeDirection) -> Void
    ) -> some View {
        modifier(SwipeDetector(
            onSwipe: action,
            minimumDistance: minimumDistance,
            velocityThreshold: velocityThreshold
        ))
    }

    func onTrackpadSwipe(
        perform action: @escaping (SwipeDirection) -> Void
    ) -> some View {
        overlay {
            TrackpadSwipeOverlay(onSwipe: action)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Trackpad Two-Finger Swipe

/// Transparent overlay that uses a local event monitor to capture two-finger
/// horizontal trackpad scroll gestures without blocking clicks or taps.
struct TrackpadSwipeOverlay: NSViewRepresentable {
    let onSwipe: (SwipeDirection) -> Void

    func makeNSView(context: Context) -> TrackpadSwipeView {
        let view = TrackpadSwipeView()
        view.onSwipe = onSwipe
        return view
    }

    func updateNSView(_ nsView: TrackpadSwipeView, context: Context) {
        nsView.onSwipe = onSwipe
    }
}

final class TrackpadSwipeView: NSView {
    var onSwipe: ((SwipeDirection) -> Void)?

    private var monitor: Any?
    private var accumulatedDeltaX: CGFloat = 0
    private var hasFired = false
    private let threshold: CGFloat = 30

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handleScroll(event)
                return event
            }
        } else if window == nil {
            removeMonitor()
        }
    }

    private func handleScroll(_ event: NSEvent) {
        guard let window, event.window == window,
              event.hasPreciseScrollingDeltas else { return }

        switch event.phase {
        case .began:
            accumulatedDeltaX = 0
            hasFired = false

        case .changed:
            guard !hasFired else { return }
            accumulatedDeltaX += event.scrollingDeltaX

            if abs(accumulatedDeltaX) >= threshold {
                hasFired = true
                let direction: SwipeDirection = accumulatedDeltaX < 0 ? .left : .right
                DispatchQueue.main.async { [weak self] in
                    self?.onSwipe?(direction)
                }
            }

        case .ended, .cancelled:
            accumulatedDeltaX = 0
            hasFired = false

        default:
            break
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit {
        removeMonitor()
    }
}
