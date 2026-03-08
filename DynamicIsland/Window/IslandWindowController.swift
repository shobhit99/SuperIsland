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
        let screenFrame = screen.frame
        let hasNotch = ScreenDetector.hasNotch(screen: screen)
        let notchRect = ScreenDetector.notchRect(screen: screen)

        let windowWidth = size.width
        let windowHeight = size.height

        let x: CGFloat
        let y: CGFloat

        if hasNotch, let notch = notchRect {
            // Center the window over the notch area
            x = notch.midX - windowWidth / 2
            if appState.currentState == .compact {
                y = notch.midY - (windowHeight / 2) + Constants.compactNotchVerticalOffset
            } else {
                // Keep expanded states pinned to the top edge so the upper corners remain usable.
                y = notch.maxY - windowHeight - Constants.expandedTopInset
            }
        } else {
            // Top center of screen
            x = screenFrame.midX - windowWidth / 2
            y = screenFrame.maxY - windowHeight - Constants.expandedTopInset
        }

        let frame = NSRect(x: x, y: y, width: windowWidth, height: windowHeight)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(
                    controlPoints: 0.22,
                    0.9,
                    0.24,
                    1.0
                )
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
            .sink { [weak self] _ in
                guard let self, let panel = self.panel else { return }
                self.applyFrame(size: self.appState.windowSize, to: panel, animated: true)
            }
            .store(in: &cancellables)
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
