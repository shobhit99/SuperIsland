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
    private var activeSpaceObserver: Any?
    private var fullscreenPollTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var shrinkWorkItem: DispatchWorkItem?
    private var isHiddenForFullscreen = false

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
        observeFullscreenChanges()
        updateFullscreenVisibility()
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
                // Keep the compact frame in sync with settings that change its
                // content size (e.g. toggling "Hide side slots" on notch Macs).
                self.updateCompactFrameIfNeeded()
                // Re-evaluate fullscreen visibility when the toggle changes.
                self.updateFullscreenVisibility()
            }
        }
    }

    // MARK: - Fullscreen hiding (non-notch Macs)
    //
    // On non-notch Macs the island floats over normal app windows, which
    // is distracting when another app is in true fullscreen (e.g. a video
    // player). When the user opts in via Settings we hide the panel while
    // any non-SuperIsland window matches the screen frame exactly, and
    // restore it as soon as that fullscreen window goes away.

    private func observeFullscreenChanges() {
        // activeSpaceDidChange fires when the user enters/exits fullscreen
        // (each fullscreen app gets its own space) or switches spaces.
        activeSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateFullscreenVisibility()
            }
        }

        // Low-frequency safety net: some fullscreen transitions (e.g. the
        // native video player going fullscreen in-place) don't always fire
        // a space change notification, so re-check every 2s while the
        // controller is alive. The check is cheap (CGWindowListCopyWindowInfo
        // with bounds only) and only runs as long as the app is up.
        fullscreenPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateFullscreenVisibility()
            }
        }
    }

    private func updateFullscreenVisibility() {
        guard let panel else { return }

        // The feature is scoped to non-notch Macs per issue #18 — on notch
        // Macs the island lives in the hardware cutout and doesn't overlap
        // fullscreen content.
        let shouldConsider = appState.hideOnFullscreen && !appState.presentationHasNotch
        guard shouldConsider else {
            if isHiddenForFullscreen {
                isHiddenForFullscreen = false
                panel.orderFrontRegardless()
            }
            return
        }

        let screen = panel.screen
            ?? ScreenDetector.activeScreen
            ?? ScreenDetector.primaryScreen
            ?? NSScreen.screens.first
        guard let screen else { return }

        let fullscreen = Self.isFullscreenWindowPresent(on: screen)

        if fullscreen && !isHiddenForFullscreen {
            isHiddenForFullscreen = true
            panel.orderOut(nil)
        } else if !fullscreen && isHiddenForFullscreen {
            isHiddenForFullscreen = false
            panel.orderFrontRegardless()
        }
    }

    /// Returns true when any on-screen window from another process exactly
    /// covers the given screen's frame — the classic signature of a native
    /// macOS fullscreen app.
    private static func isFullscreenWindowPresent(on screen: NSScreen) -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        let ourPID = Int(ProcessInfo.processInfo.processIdentifier)
        let screenFrame = screen.frame

        for window in info {
            // Skip windows owned by SuperIsland itself.
            if let pid = window[kCGWindowOwnerPID as String] as? Int, pid == ourPID {
                continue
            }
            // Only consider windows in the normal content layer. The menu
            // bar, Dock, and status items live on non-zero layers.
            if let layer = window[kCGWindowLayer as String] as? Int, layer != 0 {
                continue
            }
            guard let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                continue
            }
            // CGWindow bounds use pixel sizes; compare width/height with a
            // small tolerance to guard against rounding on Retina screens.
            if abs(rect.width - screenFrame.width) < 1.5
                && abs(rect.height - screenFrame.height) < 1.5 {
                return true
            }
        }
        return false
    }

    deinit {
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = defaultsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = activeSpaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        fullscreenPollTimer?.invalidate()
        cancellables.removeAll()
    }
}
