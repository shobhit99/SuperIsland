import SwiftUI

struct PillShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    init(cornerRadius: CGFloat) {
        self.topCornerRadius = cornerRadius
        self.bottomCornerRadius = cornerRadius
    }

    init(topCornerRadius: CGFloat, bottomCornerRadius: CGFloat) {
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let maxRadius = min(rect.width, rect.height) / 2
        let topRadius = min(topCornerRadius, maxRadius)
        let bottomRadius = min(bottomCornerRadius, maxRadius)

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + topRadius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY))

        if topRadius > 0 {
            path.addArc(
                center: CGPoint(x: rect.maxX - topRadius, y: rect.minY + topRadius),
                radius: topRadius,
                startAngle: .degrees(-90),
                endAngle: .degrees(0),
                clockwise: false
            )
        }

        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRadius))

        if bottomRadius > 0 {
            path.addArc(
                center: CGPoint(x: rect.maxX - bottomRadius, y: rect.maxY - bottomRadius),
                radius: bottomRadius,
                startAngle: .degrees(0),
                endAngle: .degrees(90),
                clockwise: false
            )
        }

        path.addLine(to: CGPoint(x: rect.minX + bottomRadius, y: rect.maxY))

        if bottomRadius > 0 {
            path.addArc(
                center: CGPoint(x: rect.minX + bottomRadius, y: rect.maxY - bottomRadius),
                radius: bottomRadius,
                startAngle: .degrees(90),
                endAngle: .degrees(180),
                clockwise: false
            )
        }

        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topRadius))

        if topRadius > 0 {
            path.addArc(
                center: CGPoint(x: rect.minX + topRadius, y: rect.minY + topRadius),
                radius: topRadius,
                startAngle: .degrees(180),
                endAngle: .degrees(270),
                clockwise: false
            )
        }

        path.closeSubpath()
        return path
    }
}
