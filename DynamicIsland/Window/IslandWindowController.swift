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
