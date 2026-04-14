import SwiftUI
import AppKit

// MARK: - Preference key for measuring text height

private struct TextHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - Scroll-wheel catcher
//
// Transparent NSView that claims hits ONLY for scroll-wheel events.
// Clicks and hovers pass straight through to the buttons layered above it.

struct TeleprompterScrollWheelCatcher: NSViewRepresentable {
    let onScroll: (CGFloat, Bool) -> Void   // (deltaY, hasPreciseScrollingDeltas)

    func makeNSView(context: Context) -> NSView {
        let view = _ScrollWheelNSView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? _ScrollWheelNSView)?.onScroll = onScroll
    }
}

private final class _ScrollWheelNSView: NSView {
    var onScroll: ((CGFloat, Bool) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.scrollingDeltaY, event.hasPreciseScrollingDeltas)
    }

    /// Consume swipe gestures so Mission Control / Space switching never fires.
    override func swipe(with event: NSEvent) { /* swallow */ }
    override func beginGesture(with event: NSEvent) { /* swallow */ }
    override func endGesture(with event: NSEvent) { /* swallow */ }

    override func wantsScrollEventsForSwipeTracking(on axis: NSEvent.GestureAxis) -> Bool {
        return true
    }

    override func wantsForwardedScrollEvents(for axis: NSEvent.GestureAxis) -> Bool {
        return true
    }

    /// Claim hits for the whole gesture family — not just `.scrollWheel`.
    /// When the user's scroll reaches a boundary, AppKit starts emitting
    /// `.swipe` / `.beginGesture` / `.endGesture` events as separate types.
    /// If we only claim `.scrollWheel`, those events slip through to the
    /// system gesture recognizer and switch Spaces.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = window?.currentEvent else { return nil }
        switch event.type {
        case .scrollWheel, .swipe, .beginGesture, .endGesture,
             .magnify, .rotate, .smartMagnify, .pressure, .gesture:
            let local = convert(point, from: superview)
            return bounds.contains(local) ? self : nil
        default:
            return nil
        }
    }
}

// MARK: - Scrolling text engine

struct TeleprompterScrollingTextView: View {
    let containerHeight: CGFloat

    @ObservedObject private var manager = TeleprompterManager.shared
    @State private var offset: CGFloat = 0
    @State private var textHeight: CGFloat = 0
    @State private var scrollTimer: Timer?
    @State private var appliedNudge: CGFloat = 0

    private var maxOffset: CGFloat {
        max(0, textHeight - containerHeight)
    }

    var body: some View {
        GeometryReader { geo in
            textBlock(width: geo.size.width)
                .offset(y: -offset)
        }
        .clipped()
        .mask(bottomFade)
        .onPreferenceChange(TextHeightKey.self) { textHeight = $0 }
        .onChange(of: manager.isPlaying) { _, playing in
            playing ? startScrolling() : stopScrolling()
        }
        .onChange(of: manager.resetToken) { _, _ in
            stopScrolling()
            appliedNudge = manager.scrollNudge
            withAnimation(.easeOut(duration: 0.25)) { offset = 0 }
        }
        .onChange(of: manager.scriptText) { _, _ in
            offset = 0; textHeight = 0
            appliedNudge = manager.scrollNudge
        }
        .onChange(of: manager.scrollNudge) { _, total in
            let delta = total - appliedNudge
            appliedNudge = total
            offset = max(0, min(maxOffset, offset + delta))
        }
        .onDisappear { stopScrolling() }
    }

    private func textBlock(width: CGFloat) -> some View {
        let frameAlign: Alignment = {
            switch manager.textAlignment {
            case .leading:  return .topLeading
            case .trailing: return .topTrailing
            default:        return .top
            }
        }()

        return Text(manager.scriptText)
            .font(.system(size: manager.fontSize, weight: .regular))
            .foregroundColor(.white.opacity(0.92))
            .lineSpacing(manager.fontSize * 0.35)
            .multilineTextAlignment(manager.textAlignment)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: frameAlign)
            .padding(.top, containerHeight / 2)
            .padding(.bottom, containerHeight)
            .background(
                GeometryReader { g in
                    Color.clear.preference(key: TextHeightKey.self, value: g.size.height)
                }
            )
    }

    private var bottomFade: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.00),
                .init(color: .black, location: 0.20),
                .init(color: .black, location: 0.74),
                .init(color: .clear, location: 1.00)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func startScrolling() {
        stopScrolling()
        scrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            Task { @MainActor in
                guard manager.isPlaying else { return }
                let delta = CGFloat(manager.scrollSpeed / 60.0)
                let next = min(offset + delta, maxOffset)
                offset = next
                if maxOffset > 0, next >= maxOffset { manager.pause() }
            }
        }
    }

    private func stopScrolling() {
        scrollTimer?.invalidate()
        scrollTimer = nil
    }
}

// MARK: - Compact expanded (408 × 88)

private struct TeleprompterExpandedInner: View {
    @ObservedObject private var manager = TeleprompterManager.shared

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "scroll")
                .font(.system(size: 22))
                .foregroundColor(.white.opacity(manager.isPlaying ? 0.85 : 0.28))
                .symbolEffect(.pulse, isActive: manager.isPlaying)
                .frame(width: 26)

            GeometryReader { geo in
                if manager.hasScript {
                    TeleprompterScrollingTextView(containerHeight: geo.size.height)
                } else {
                    addScriptPrompt(size: 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 8) {
                iconButton("arrow.counterclockwise", size: 12) { manager.reset() }
                iconButton(
                    manager.isPlaying || manager.isCountingDown ? "pause.fill" : "play.fill",
                    size: 14, bold: true
                ) { manager.togglePlayPause() }
            }
        }
    }
}

// MARK: - Full expanded (658 × 180)

private struct TeleprompterFullExpandedInner: View {
    @ObservedObject private var manager = TeleprompterManager.shared
    @State private var spaceMonitor: Any?

    var body: some View {
        ZStack(alignment: .topLeading) {

            // ── Full-height scrolling text ────────────────────────────────
            GeometryReader { geo in
                if manager.hasScript {
                    TeleprompterScrollingTextView(containerHeight: geo.size.height)
                } else {
                    addScriptPrompt(size: 14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // ── Scroll-wheel catcher (transparent to clicks) ──────────────
            if manager.hasScript {
                TeleprompterScrollWheelCatcher { deltaY, isPrecise in
                    let pxPerLine = manager.fontSize * 1.4
                    // Direction: scroll UP = rewind, scroll DOWN = fast-forward.
                    let nudge: CGFloat = isPrecise
                        ? -deltaY * 1.2
                        : -deltaY * pxPerLine
                    manager.nudgeOffset(by: nudge)
                }
            }

            // ── 3-2-1 Countdown overlay ───────────────────────────────────
            if let n = manager.countdownValue {
                Text("\(n)")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 1.3).combined(with: .opacity),
                        removal: .scale(scale: 0.7).combined(with: .opacity)
                    ))
                    .animation(.spring(duration: 0.3), value: n)
                    .id(n)
            }

            // ── Top bar ───────────────────────────────────────────────────
            topBar
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear  { installSpaceMonitor() }
        .onDisappear { removeSpaceMonitor() }
    }

    // MARK: - Space-bar keyboard shortcut (app-local)

    private func installSpaceMonitor() {
        guard spaceMonitor == nil else { return }
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // keyCode 49 = space. Ignore when a text field has focus (editor window).
            guard event.keyCode == 49,
                  !(event.window?.firstResponder is NSTextView)
            else { return event }
            Task { @MainActor in manager.togglePlayPause() }
            return nil // consume
        }
    }

    private func removeSpaceMonitor() {
        if let m = spaceMonitor {
            NSEvent.removeMonitor(m)
            spaceMonitor = nil
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 0) {
            // Left: reset + play/pause
            HStack(spacing: 14) {
                iconButton("arrow.counterclockwise", size: 15) { manager.reset() }
                iconButton(
                    manager.isPlaying || manager.isCountingDown ? "pause.circle.fill" : "play.circle.fill",
                    size: 26, bold: true
                ) { manager.togglePlayPause() }
            }

            Spacer()

            // Right: font, alignment, speed, edit
            HStack(spacing: 10) {
                // Font size
                iconButton("textformat.size.smaller", size: 14) {
                    manager.fontSize = max(12, manager.fontSize - 2)
                }
                iconButton("textformat.size.larger", size: 14) {
                    manager.fontSize = min(40, manager.fontSize + 2)
                }

                barDivider

                // Alignment
                alignButton(index: 0, icon: "text.alignleft")
                alignButton(index: 1, icon: "text.aligncenter")
                alignButton(index: 2, icon: "text.alignright")

                barDivider

                // Speed
                iconButton("minus.circle", size: 14) {
                    manager.scrollSpeed = max(1, manager.scrollSpeed - 2)
                }
                iconButton("plus.circle", size: 14) {
                    manager.scrollSpeed = min(30, manager.scrollSpeed + 2)
                }

                barDivider

                // Edit
                Button { TeleprompterScriptEditorWindowController.show() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "pencil")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Edit")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.white.opacity(0.38))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule(style: .continuous).fill(.white.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .hoverPointer()
            }
        }
    }

    @ViewBuilder
    private func alignButton(index: Int, icon: String) -> some View {
        let active = manager.textAlignmentIndex == index
        Button { manager.textAlignmentIndex = index } label: {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(active ? 0.9 : 0.28))
        }
        .buttonStyle(.plain)
        .hoverPointer()
    }

    private var barDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.12))
            .frame(width: 1, height: 12)
            .padding(.horizontal, 2)
    }
}

// MARK: - Shared helpers

@ViewBuilder
private func addScriptPrompt(size: CGFloat) -> some View {
    Button { TeleprompterScriptEditorWindowController.show() } label: {
        HStack(spacing: 5) {
            Image(systemName: "plus.circle")
            Text("Add script")
                .font(.system(size: size, weight: .medium))
        }
        .font(.system(size: size))
        .foregroundColor(.white.opacity(0.25))
    }
    .buttonStyle(.plain)
    .hoverPointer()
}

@ViewBuilder
private func iconButton(
    _ icon: String,
    size: CGFloat,
    bold: Bool = false,
    action: @escaping () -> Void
) -> some View {
    Button(action: action) {
        Image(systemName: icon)
            .font(.system(size: size, weight: bold ? .bold : .regular))
            .foregroundColor(.white.opacity(bold ? 1.0 : 0.55))
    }
    .buttonStyle(.plain)
    .hoverPointer()
}

// MARK: - Public entry point

struct TeleprompterExpandedView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if appState.currentState == .fullExpanded {
            TeleprompterFullExpandedInner()
        } else {
            TeleprompterExpandedInner()
        }
    }
}
