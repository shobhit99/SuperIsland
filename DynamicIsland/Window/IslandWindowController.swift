import AppKit
import SwiftUI
import Combine

final class IslandWindowController {
    private var panel: IslandPanel?
    private let appState = AppState.shared
    private var screenObserver: Any?
    private var cancellables = Set<AnyCancellable>()

    func showIsland() {
        let panel = IslandPanel()
        self.panel = panel

        let hostingView = NSHostingView(
            rootView: IslandContainerView()
                .environmentObject(appState)
        )
        hostingView.frame = panel.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]

        // Make hosting view background transparent
        hostingView.layer?.backgroundColor = .clear

        panel.contentView = hostingView
        positionIsland(on: panel)
        panel.orderFrontRegardless()

        observeScreenChanges()
        observeStateChanges()
    }

    func hideIsland() {
        panel?.orderOut(nil)
    }

    // MARK: - Positioning

    private func positionIsland(on panel: IslandPanel) {
        let size = appState.currentSize
        applyFrame(size: size, to: panel, animated: false)
    }

    private func applyFrame(size: CGSize, to panel: IslandPanel, animated: Bool) {
        guard let screen = NSScreen.main else { return }
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
            y = screenFrame.maxY - windowHeight
        } else {
            // Top center of screen
            x = screenFrame.midX - windowWidth / 2
            y = screenFrame.maxY - windowHeight
        }

        let frame = NSRect(x: x, y: y, width: windowWidth, height: windowHeight)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
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
                self.applyFrame(size: self.appState.currentSize, to: panel, animated: true)
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
            guard let self, let panel = self.panel else { return }
            self.positionIsland(on: panel)
        }
    }

    deinit {
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        cancellables.removeAll()
    }
}
