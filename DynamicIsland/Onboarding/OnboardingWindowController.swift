import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let onComplete: () -> Void
    private let onClose: () -> Void
    private var didComplete = false

    init(onComplete: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.onComplete = onComplete
        self.onClose = onClose

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to DynamicIsland"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.center()

        super.init(window: window)

        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: OnboardingView(onFinish: { [weak self] in
                self?.completeOnboarding()
            })
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(sender)
    }

    func windowWillClose(_ notification: Notification) {
        guard !didComplete else { return }
        onClose()
    }

    private func completeOnboarding() {
        guard !didComplete else { return }
        didComplete = true
        onComplete()
        close()
    }
}
