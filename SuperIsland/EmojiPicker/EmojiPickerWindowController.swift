import AppKit
import SwiftUI

private final class FirstMousePanelHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class EmojiPickerWindowController {
    private let panel: NSPanel
    private let hostingView: FirstMousePanelHostingView<EmojiPickerView>

    init(manager: EmojiPickerManager) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: manager.width, height: manager.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false

        hostingView = FirstMousePanelHostingView(rootView: EmojiPickerView(manager: manager))
        hostingView.frame = panel.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
    }

    func show(anchor: CGPoint, screenFrame: CGRect, height: CGFloat) {
        let width = hostingView.rootView.manager.width
        let x = min(max(screenFrame.minX + 12, anchor.x - (width / 2)), screenFrame.maxX - width - 12)
        let y = max(screenFrame.minY + 12, anchor.y - height - 10)
        let frame = NSRect(x: x, y: y, width: width, height: height)

        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}
