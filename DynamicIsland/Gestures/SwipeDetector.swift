import SwiftUI

struct SwipeDetector: ViewModifier {
    let onSwipe: (SwipeDirection) -> Void
    var minimumDistance: CGFloat = 20
    var velocityThreshold: CGFloat = 100

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: minimumDistance)
                .onEnded { value in
                    let horizontal = value.translation.width
                    let vertical = value.translation.height
                    let velocity = sqrt(
                        pow(value.velocity.width, 2) + pow(value.velocity.height, 2)
                    )

                    guard velocity > velocityThreshold else { return }

                    if abs(horizontal) > abs(vertical) {
                        onSwipe(horizontal > 0 ? .right : .left)
                    } else {
                        onSwipe(vertical > 0 ? .down : .up)
                    }
                }
        )
    }
}

extension View {
    func onSwipe(
        minimumDistance: CGFloat = 20,
        velocityThreshold: CGFloat = 100,
        perform action: @escaping (SwipeDirection) -> Void
    ) -> some View {
        modifier(SwipeDetector(
            onSwipe: action,
            minimumDistance: minimumDistance,
            velocityThreshold: velocityThreshold
        ))
    }
}
