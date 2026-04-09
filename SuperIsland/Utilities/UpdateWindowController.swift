import AppKit
import SwiftUI

@MainActor
final class UpdateWindowController {
    private let window: NSWindow

    init(version: String, releaseURL: URL) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 210),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.isOpaque = true
        window.backgroundColor = NSColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1)
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.minSize = CGSize(width: 300, height: 210)
        window.maxSize = CGSize(width: 300, height: 210)

        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        let rootView = UpdateDialogView(
            version: version,
            releaseURL: releaseURL,
            onDismiss: { [weak self] in self?.close() }
        )
        window.contentViewController = NSHostingController(rootView: rootView)
    }

    func show() {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.orderOut(nil)
    }
}
