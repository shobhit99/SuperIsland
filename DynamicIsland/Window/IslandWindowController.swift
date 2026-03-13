import AppKit
import SwiftUI
import Combine

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class IslandWindowController {
    private var panel: IslandPanel?
    private let appState = AppState.shared
    private var screenObserver: Any?
    private var defaultsObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    private var previousState: IslandState = .compact
    private var blurTimer: Timer?

    func showIsland() {
        let panel = IslandPanel()
        self.panel = panel

        let hostingView = FirstMouseHostingView(
            rootView: IslandContainerView()
                .environmentObject(appState)
        )
        hostingView.frame = panel.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true

        // Make hosting view background transparent
        hostingView.layer?.backgroundColor = .clear
        hostingView.layer?.masksToBounds = false

        panel.contentView = hostingView
        positionIsland(on: panel)
        panel.setVisibleInScreenRecordings(appState.showInScreenRecordings)
        panel.makeKeyAndOrderFront(nil)

        observeScreenChanges()
        observeSettingsChanges()
        observeStateChanges()
    }

    func hideIsland() {
        panel?.orderOut(nil)
    }

    // MARK: - Positioning

    private func positionIsland(on panel: IslandPanel) {
        let size = appState.windowSize
        applyFrame(size: size, to: panel, animated: false)
    }

    private func applyFrame(size: CGSize, to panel: IslandPanel, animated: Bool) {
        guard let screen = panel.screen
            ?? ScreenDetector.activeScreen
            ?? ScreenDetector.primaryScreen
            ?? NSScreen.screens.first else { return }
        appState.updatePresentationContext(screen: screen)
        let screenFrame = screen.frame
        let hasNotch = ScreenDetector.hasNotch(screen: screen)
        let notchRect = ScreenDetector.notchRect(screen: screen)

        let windowWidth = size.width
        let windowHeight = size.height

        let anchorX: CGFloat
        let anchorY: CGFloat

        if hasNotch, let notch = notchRect {
            anchorX = notch.midX
            anchorY = notch.maxY - Constants.expandedTopInset
        } else {
            anchorX = screenFrame.midX
            anchorY = screenFrame.maxY - Constants.expandedTopInset
        }

        let x = anchorX - windowWidth / 2
        let y = anchorY - windowHeight

        let frame = NSRect(x: x, y: y, width: windowWidth, height: windowHeight)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = appState.currentState == .compact ? 0.54 : 0.48
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func observeStateChanges() {
        appState.$currentState
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] newState in
                guard let self, let panel = self.panel else { return }
                let oldState = self.previousState
                self.previousState = newState
                self.applyFrame(size: self.appState.windowSize, to: panel, animated: true)

                let oldSize = self.appState.windowSize(for: oldState)
                let newSize = self.appState.windowSize(for: newState)
                let isGrowing = newSize.width > oldSize.width || newSize.height > oldSize.height
                let isShrinking = newSize.width < oldSize.width || newSize.height < oldSize.height

                if isGrowing {
                    self.applyExpansionBlur()
                } else if isShrinking {
                    self.applyShrinkBlur()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Transition Blur
    //
    // Uses NSView.contentFilters (AppKit-level, NOT CALayer.backgroundFilters
    // which is broken on macOS 11+). CIGaussianBlur is applied directly to
    // the hosting view's rendered content. A Timer drives the radius animation
    // because contentFilters is not implicitly animatable.

    /// Expanding: start fully blurred, hold briefly, then ease-out to sharp.
    private func applyExpansionBlur() {
        guard let contentView = panel?.contentView else { return }
        clearBlur()
        setBlurRadius(20.0, on: contentView)

        // Hold 180 ms, then animate radius → 0 over 320 ms.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            self?.animateBlur(from: 20.0, to: 0, duration: 0.32, easeOut: true)
        }
    }

    /// Shrinking: ramp blur from 0 → max as the island collapses.
    private func applyShrinkBlur() {
        guard panel?.contentView != nil else { return }
        clearBlur()
        animateBlur(from: 0, to: 18.0, duration: 0.36, easeOut: false)
    }

    private func animateBlur(from: CGFloat, to: CGFloat, duration: TimeInterval, easeOut: Bool) {
        blurTimer?.invalidate()
        let startTime = CACurrentMediaTime()

        blurTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { timer in
            Task { @MainActor [weak self] in
                guard let self, let contentView = self.panel?.contentView else {
                    timer.invalidate()
                    return
                }

                let elapsed = CACurrentMediaTime() - startTime
                var t = min(elapsed / duration, 1.0)
                t = easeOut ? (1 - pow(1 - t, 3)) : (t * t)

                let radius = from + (to - from) * CGFloat(t)

                if elapsed >= duration {
                    timer.invalidate()
                    self.blurTimer = nil
                    if to < 0.5 {
                        contentView.contentFilters = []
                    } else {
                        self.setBlurRadius(to, on: contentView)
                    }
                    return
                }

                self.setBlurRadius(radius, on: contentView)
            }
        }
    }

    private func setBlurRadius(_ radius: CGFloat, on view: NSView) {
        guard radius > 0.5 else {
            view.contentFilters = []
            return
        }
        let filter = CIFilter(name: "CIGaussianBlur")!
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        view.contentFilters = [filter]
    }

    private func clearBlur() {
        blurTimer?.invalidate()
        blurTimer = nil
        panel?.contentView?.contentFilters = []
    }

    // MARK: - Screen Observation

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel else { return }
                self.positionIsland(on: panel)
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
