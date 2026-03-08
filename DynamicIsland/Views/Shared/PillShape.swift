import SwiftUI

struct PillShape: Shape {
    var topLeadingRadius: CGFloat
    var topTrailingRadius: CGFloat
    var bottomLeadingRadius: CGFloat
    var bottomTrailingRadius: CGFloat
    var outwardTopCorners: Bool
    var topCutoutWidth: CGFloat
    var topCutoutDepth: CGFloat
    var topCutoutCornerRadius: CGFloat

    init(cornerRadius: CGFloat) {
        self.topLeadingRadius = cornerRadius
        self.topTrailingRadius = cornerRadius
        self.bottomLeadingRadius = cornerRadius
        self.bottomTrailingRadius = cornerRadius
        self.outwardTopCorners = false
        self.topCutoutWidth = 0
        self.topCutoutDepth = 0
        self.topCutoutCornerRadius = 0
    }

    init(topCornerRadius: CGFloat, bottomCornerRadius: CGFloat) {
        self.topLeadingRadius = topCornerRadius
        self.topTrailingRadius = topCornerRadius
        self.bottomLeadingRadius = bottomCornerRadius
        self.bottomTrailingRadius = bottomCornerRadius
        self.outwardTopCorners = false
        self.topCutoutWidth = 0
        self.topCutoutDepth = 0
        self.topCutoutCornerRadius = 0
    }

    init(
        topLeadingRadius: CGFloat,
        topTrailingRadius: CGFloat,
        bottomLeadingRadius: CGFloat,
        bottomTrailingRadius: CGFloat,
        outwardTopCorners: Bool = false,
        topCutoutWidth: CGFloat = 0,
        topCutoutDepth: CGFloat = 0,
        topCutoutCornerRadius: CGFloat = 0
    ) {
        self.topLeadingRadius = topLeadingRadius
        self.topTrailingRadius = topTrailingRadius
        self.bottomLeadingRadius = bottomLeadingRadius
        self.bottomTrailingRadius = bottomTrailingRadius
        self.outwardTopCorners = outwardTopCorners
        self.topCutoutWidth = topCutoutWidth
        self.topCutoutDepth = topCutoutDepth
        self.topCutoutCornerRadius = topCutoutCornerRadius
    }

    func path(in rect: CGRect) -> Path {
        let maxOuterRadius = min(rect.width, rect.height) / 2
        let topLeading = min(topLeadingRadius, maxOuterRadius)
        let topTrailing = min(topTrailingRadius, maxOuterRadius)
        let bottomLeading = min(bottomLeadingRadius, maxOuterRadius)
        let bottomTrailing = min(bottomTrailingRadius, maxOuterRadius)
        let cutoutWidth = min(max(topCutoutWidth, 0), max(0, rect.width - 24))
        let cutoutDepth = min(max(topCutoutDepth, 0), max(0, rect.height - 8))
        let cutoutRadius = min(topCutoutCornerRadius, cutoutDepth, cutoutWidth / 2)
        let hasCutout = cutoutWidth > 0 && cutoutDepth > 0

        if outwardTopCorners && !hasCutout {
            return outwardTopCornerPath(
                in: rect,
                topLeading: topLeading,
                topTrailing: topTrailing,
                bottomLeading: bottomLeading,
                bottomTrailing: bottomTrailing
            )
        }

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + topLeading, y: rect.minY))

        if hasCutout {
            let cutoutMinX = rect.midX - (cutoutWidth / 2)
            let cutoutMaxX = rect.midX + (cutoutWidth / 2)

            path.addLine(to: CGPoint(x: cutoutMinX, y: rect.minY))
            path.addLine(to: CGPoint(x: cutoutMinX, y: rect.minY + cutoutDepth - cutoutRadius))

            if cutoutRadius > 0 {
                path.addArc(
                    center: CGPoint(
                        x: cutoutMinX + cutoutRadius,
                        y: rect.minY + cutoutDepth - cutoutRadius
                    ),
                    radius: cutoutRadius,
                    startAngle: .degrees(180),
                    endAngle: .degrees(90),
                    clockwise: true
                )
            }

            path.addLine(to: CGPoint(x: cutoutMaxX - cutoutRadius, y: rect.minY + cutoutDepth))

            if cutoutRadius > 0 {
                path.addArc(
                    center: CGPoint(
                        x: cutoutMaxX - cutoutRadius,
                        y: rect.minY + cutoutDepth - cutoutRadius
                    ),
                    radius: cutoutRadius,
                    startAngle: .degrees(90),
                    endAngle: .degrees(0),
                    clockwise: true
                )
            }

            path.addLine(to: CGPoint(x: rect.maxX - topTrailing, y: rect.minY))
        } else {
            path.addLine(to: CGPoint(x: rect.maxX - topTrailing, y: rect.minY))
        }

        if topTrailing > 0 {
            path.addArc(
                center: CGPoint(x: rect.maxX - topTrailing, y: rect.minY + topTrailing),
                radius: topTrailing,
                startAngle: .degrees(-90),
                endAngle: .degrees(0),
                clockwise: false
            )
        }

        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomTrailing))

        if bottomTrailing > 0 {
            path.addArc(
                center: CGPoint(x: rect.maxX - bottomTrailing, y: rect.maxY - bottomTrailing),
                radius: bottomTrailing,
                startAngle: .degrees(0),
                endAngle: .degrees(90),
                clockwise: false
            )
        }

        path.addLine(to: CGPoint(x: rect.minX + bottomLeading, y: rect.maxY))

        if bottomLeading > 0 {
            path.addArc(
                center: CGPoint(x: rect.minX + bottomLeading, y: rect.maxY - bottomLeading),
                radius: bottomLeading,
                startAngle: .degrees(90),
                endAngle: .degrees(180),
                clockwise: false
            )
        }

        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topLeading))

        if topLeading > 0 {
            path.addArc(
                center: CGPoint(x: rect.minX + topLeading, y: rect.minY + topLeading),
                radius: topLeading,
                startAngle: .degrees(180),
                endAngle: .degrees(270),
                clockwise: false
            )
        }

        path.closeSubpath()
        return path
    }

    private func outwardTopCornerPath(
        in rect: CGRect,
        topLeading: CGFloat,
        topTrailing: CGFloat,
        bottomLeading: CGFloat,
        bottomTrailing: CGFloat
    ) -> Path {
        var path = Path()
        let leftWallX = rect.minX + topLeading
        let rightWallX = rect.maxX - topTrailing

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        if topLeading > 0 {
            path.addQuadCurve(
                to: CGPoint(x: leftWallX, y: rect.minY + topLeading),
                control: CGPoint(x: leftWallX, y: rect.minY)
            )
        } else {
            path.addLine(to: CGPoint(x: leftWallX, y: rect.minY))
        }

        path.addLine(to: CGPoint(x: leftWallX, y: rect.maxY - bottomLeading))

        if bottomLeading > 0 {
            path.addQuadCurve(
                to: CGPoint(x: leftWallX + bottomLeading, y: rect.maxY),
                control: CGPoint(x: leftWallX, y: rect.maxY)
            )
        } else {
            path.addLine(to: CGPoint(x: leftWallX, y: rect.maxY))
        }

        path.addLine(to: CGPoint(x: rightWallX - bottomTrailing, y: rect.maxY))

        if bottomTrailing > 0 {
            path.addQuadCurve(
                to: CGPoint(x: rightWallX, y: rect.maxY - bottomTrailing),
                control: CGPoint(x: rightWallX, y: rect.maxY)
            )
        } else {
            path.addLine(to: CGPoint(x: rightWallX, y: rect.maxY))
        }

        path.addLine(to: CGPoint(x: rightWallX, y: rect.minY + topTrailing))

        if topTrailing > 0 {
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.minY),
                control: CGPoint(x: rightWallX, y: rect.minY)
            )
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }

        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
