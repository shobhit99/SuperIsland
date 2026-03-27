import AppKit
import SwiftUI
import Combine

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Container that keeps the hosting view centered horizontally and
/// pinned to the top, regardless of the container/window size.
/// Unlike autoresizingMask, this handles the 0-margin edge case correctly.
private final class CenteringContainerView: NSView {
    override func layout() {
        super.layout()
        guard let hostingView = subviews.first else { return }
        hostingView.frame.origin.x = (bounds.width - hostingView.frame.width) / 2
        // AppKit coords: y=0 at bottom. Pin hosting view top to container top.
        hostingView.frame.origin.y = bounds.height - hostingView.frame.height
    }
}

@MainActor
final class IslandWindowController {
    private var panel: IslandPanel?
    private let appState = AppState.shared
    private var screenObserver: Any?
    private var defaultsObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    private var shrinkWorkItem: DispatchWorkItem?

    func showIsland() {
        let panel = IslandPanel()
        self.panel = panel

        // Initialize presentation context first so size calculations work.
        if let screen = panel.screen
            ?? ScreenDetector.activeScreen
            ?? ScreenDetector.primaryScreen
            ?? NSScreen.screens.first {
            appState.updatePresentationContext(screen: screen)
        }

        // The hosting view is set to the MAXIMUM possible size and
        // NEVER resizes. The window acts as a clipping viewport:
        // compact window → only the notch area is visible/clickable,
        // expanded window → the full surface is revealed.
        // Because the hosting view never changes size, SwiftUI never
        // re-layouts from window changes — no "jump left" on expand.
        let maxSize = maxWindowSize
        let hostingView = FirstMouseHostingView(
            rootView: IslandContainerView()
                .environmentObject(appState)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: maxSize.width, height: maxSize.height)
        hostingView.autoresizingMask = [] // Never resize — container handles positioning.

        let containerView = CenteringContainerView()
        containerView.addSubview(hostingView)
        panel.contentView = containerView

        applyFrame(size: appState.windowSize, to: panel)

        panel.setVisibleInScreenRecordings(appState.showInScreenRecordings)
        panel.makeKeyAndOrderFront(nil)

        setupDidChangeStateHook()
        observeScreenChanges()
        observeSettingsChanges()
        observeStateChanges()
        observeCompactLayoutChanges()
    }

    func hideIsland() {
        panel?.orderOut(nil)
    }

    // MARK: - Positioning

    private var maxWindowSize: CGSize {
        let full = appState.windowSize(for: .fullExpanded)
        let expanded = appState.windowSize(for: .expanded)
        return CGSize(
            width: max(full.width, expanded.width),
            height: max(full.height, expanded.height)
        )
    }

    private func applyFrame(size: CGSize, to panel: IslandPanel, display: Bool = true) {
        guard let screen = panel.screen
            ?? ScreenDetector.activeScreen
            ?? ScreenDetector.primaryScreen
            ?? NSScreen.screens.first else { return }
        appState.updatePresentationContext(screen: screen)
        let screenFrame = screen.frame
        let hasNotch = ScreenDetector.hasNotch(screen: screen)
        let notchRect = ScreenDetector.notchRect(screen: screen)

        let anchorX: CGFloat
        let anchorY: CGFloat
        if hasNotch, let notch = notchRect {
            anchorX = notch.midX
            anchorY = notch.maxY - Constants.expandedTopInset
        } else {
            anchorX = screenFrame.midX
            anchorY = screenFrame.maxY - Constants.expandedTopInset
        }

        let x = anchorX - size.width / 2
        let y = anchorY - size.height
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: display)
    }

    // MARK: - Window resize via didSet hook
    //
    // Fires from AppState.didSet — AFTER currentState has changed,
    // still INSIDE the withAnimation() block. No GeometryReader exists,
    // so the resize is invisible to SwiftUI. The surface stays centered
    // on the notch because both the window and surface are notch-centered.

    private func setupDidChangeStateHook() {
        appState.didChangeState = { [weak self] oldState, newState in
            guard let self, let panel = self.panel else { return }
            let oldSize = self.appState.windowSize(for: oldState)
            let newSize = self.appState.windowSize(for: newState)

            if newSize.width > oldSize.width || newSize.height > oldSize.height {
                // The hosting view is fixed-size, so this resize only
                // changes the visible viewport — no SwiftUI re-layout.
                self.applyFrame(size: self.maxWindowSize, to: panel)

                // Refresh tracking areas after the viewport change so
                // .onContinuousHover picks up the correct hover state.
                panel.contentView?.subviews.forEach {
                    $0.updateTrackingAreas()
                }
            }
            // SHRINKING: keep window large during animation.
            // It's snapped to compact in observeStateChanges after 0.55s.
        }
    }

    // MARK: - State observation (dismiss scheduling + delayed shrink)

    private func observeStateChanges() {
        appState.$currentState
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] newState in
                guard let self, let panel = self.panel else { return }

                self.shrinkWorkItem?.cancel()
                self.shrinkWorkItem = nil

                switch newState {
                case .expanded, .fullExpanded:
                    self.appState.suppressDismissScheduling = true
                    self.appState.cancelAutoDismiss()
                    self.appState.cancelFullExpandedDismiss()

                    // After the animation settles, re-enable dismiss and
                    // schedule it if the user isn't hovering. The 0.8s
                    // delay gives tracking areas time to stabilize after
                    // the window resize.
                    let expectedState = newState
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                        guard let self else { return }
                        self.appState.suppressDismissScheduling = false

                        // Refresh tracking areas so hover state is accurate.
                        panel.contentView?.subviews.forEach {
                            $0.updateTrackingAreas()
                        }

                        guard self.appState.currentState == expectedState,
                              !self.appState.isHovering else { return }
                        if expectedState == .expanded {
                            self.appState.scheduleAutoDismiss()
                        } else {
                            self.appState.scheduleFullExpandedDismiss()
                        }
                    }

                case .compact:
                    self.appState.suppressDismissScheduling = false
                    // Shrink window AFTER the animation finishes.
                    // This releases the expanded click area.
                    let work = DispatchWorkItem { [weak self] in
                        guard let self, let panel = self.panel,
                              self.appState.currentState == .compact else { return }
                        self.applyFrame(size: self.appState.windowSize, to: panel)
                        // Force tracking area recalculation so the next
                        // hover on the compact notch is detected.
                        panel.contentView?.subviews.forEach {
                            $0.updateTrackingAreas()
                        }
                    }
                    self.shrinkWorkItem = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Compact layout changes

    private func observeCompactLayoutChanges() {
        appState.$activeModule
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateCompactFrameIfNeeded()
            }
            .store(in: &cancellables)

        NowPlayingManager.shared.$title
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateCompactFrameIfNeeded()
            }
            .store(in: &cancellables)
    }

    private func updateCompactFrameIfNeeded() {
        guard let panel, appState.currentState == .compact else { return }
        applyFrame(size: appState.windowSize, to: panel)
    }

    // MARK: - Screen & Settings

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel else { return }
                self.applyFrame(size: self.appState.currentState == .compact
                    ? self.appState.windowSize : self.maxWindowSize, to: panel)
            }
        }
    }

    private func observeSettingsChanges() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.panel?.setVisibleInScreenRecordings(self.appState.showInScreenRecordings)
            }
        }
    }

    deinit {
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = defaultsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        cancellables.removeAll()
    }
}
