import AppKit
import SwiftUI

private struct HoverPointerModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.onHover { hovering in
            if hovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }
}

extension View {
    func hoverPointer() -> some View {
        modifier(HoverPointerModifier())
    }
}
