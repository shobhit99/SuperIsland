import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController {
    private let window: NSWindow
    private var workspaceObserver: Any?

    init(
        onComplete: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: OnboardingLayout.windowSize.width, height: OnboardingLayout.windowSize.height),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.isOpaque = true
        window.backgroundColor = NSColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1.0)
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.title = "SuperIsland Setup"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar = nil
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.animationBehavior = .default
        window.setFrameAutosaveName("")

        // Fixed size
        window.minSize = OnboardingLayout.windowSize
        window.maxSize = OnboardingLayout.windowSize
        window.standardWindowButton(.zoomButton)?.isHidden = true

        let rootView = OnboardingView(
            onComplete: onComplete,
            onOpenSettings: onOpenSettings
        )
        window.contentViewController = NSHostingController(rootView: rootView)

        // When another app deactivates (e.g. System Settings closes after granting),
        // reclaim focus so the onboarding window comes back.
        // Exception: don't steal focus while System Settings is open (e.g. for accessibility grant).
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                // Don't pull the onboarding in front if the user is interacting with System Settings
                let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                if frontmost == "com.apple.systempreferences" { return }
                self?.bringToFront()
            }
        }
    }

    deinit {
        if let o = workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
    }

    private func bringToFront() {
        guard window.isVisible else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func show() {
        window.setContentSize(OnboardingLayout.windowSize)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.orderOut(nil)
    }
}
