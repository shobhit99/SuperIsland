import AppKit
import SwiftUI
import Combine

/// Hosting view that passes through mouse events outside the island surface.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only accept hits within the island surface + gutter area.
        // Everything else passes through to windows below — just like
        // NotchDrop, whose window covers a large area but only captures
        // events on the visible notch content.
        let appState = AppState.shared
        let surfaceSize = appState.currentSize
        let boundsWidth = bounds.width

        let gutterWidth = appState.currentState == .compact
            ? 0.0
            : Constants.moduleCyclerGutterWidth
        let hitWidth = surfaceSize.width + gutterWidth * 2
        let hitMinX = (boundsWidth - hitWidth) / 2
        let hitMaxX = hitMinX + hitWidth
        let hitMaxY = surfaceSize.height + Constants.expandedShadowBottomPadding

        guard point.x >= hitMinX, point.x <= hitMaxX,
              point.y >= 0, point.y <= hitMaxY else {
            return nil
        }

        return super.hitTest(point)
    }
}

@MainActor
final class IslandWindowController {
    private var panel: IslandPanel?
    private let appState = AppState.shared
    private var screenObserver: Any?
    private var defaultsObserver: Any?
    private var cancellables = Set<AnyCancellable>()

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
        hostingView.layer?.backgroundColor = .clear
        hostingView.layer?.masksToBounds = false

        panel.contentView = hostingView

        // Set window to its FIXED size once — like NotchDrop.
        // The window never resizes; the SwiftUI surface animates within it.
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

    /// Fixed window size — large enough for ANY state.
    private var fixedWindowSize: CGSize {
        let full = appState.windowSize(for: .fullExpanded)
        let expanded = appState.windowSize(for: .expanded)
        return CGSize(
            width: max(full.width, expanded.width),
            height: max(full.height, expanded.height)
        )
    }

    private func positionIsland(on panel: IslandPanel) {
        guard let screen = panel.screen
            ?? ScreenDetector.activeScreen
            ?? ScreenDetector.primaryScreen
            ?? NSScreen.screens.first else { return }

        appState.updatePresentationContext(screen: screen)
        let screenFrame = screen.frame
        let hasNotch = ScreenDetector.hasNotch(screen: screen)
        let notchRect = ScreenDetector.notchRect(screen: screen)
        let size = fixedWindowSize

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
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    // MARK: - State observation (dismiss scheduling only — NO window resize)

    private func observeStateChanges() {
        appState.$currentState
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] newState in
                guard let self else { return }

                switch newState {
                case .expanded:
                    self.appState.suppressDismissScheduling = true
                    self.appState.cancelAutoDismiss()
                    self.appState.cancelFullExpandedDismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
                        guard let self else { return }
                        self.appState.suppressDismissScheduling = false
                        guard self.appState.currentState == .expanded,
                              !self.appState.isHovering else { return }
                        self.appState.scheduleAutoDismiss()
                    }
                case .fullExpanded:
                    self.appState.suppressDismissScheduling = true
                    self.appState.cancelAutoDismiss()
                    self.appState.cancelFullExpandedDismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
                        guard let self else { return }
                        self.appState.suppressDismissScheduling = false
                        guard self.appState.currentState == .fullExpanded,
                              !self.appState.isHovering else { return }
                        self.appState.scheduleFullExpandedDismiss()
                    }
                case .compact:
                    self.appState.suppressDismissScheduling = false
                }
            }
            .store(in: &cancellables)
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
