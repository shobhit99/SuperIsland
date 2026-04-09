import AppKit
import SwiftUI

@MainActor
final class UpdateWindowController {
    private let window: NSWindow

    init(version: String, releaseURL: URL, downloadURL: URL?) {
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
            downloadURL: downloadURL,
            onDismiss: { [weak self] in self?.close() }
        )
        window.contentViewController = NSHostingController(rootView: rootView)
    }

    func show() {
        if let screen = NSScreen.main {
            let sf = screen.visibleFrame
            let origin = NSPoint(
                x: sf.midX - window.frame.width / 2,
                y: sf.midY - window.frame.height / 2
            )
            window.setFrameOrigin(origin)
        } else {
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.orderOut(nil)
    }
}
