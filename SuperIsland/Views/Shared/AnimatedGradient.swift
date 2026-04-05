import SwiftUI

struct AnimatedGradient: View {
    let colors: [Color]
    @State private var start = UnitPoint(x: 0, y: 0)
    @State private var end = UnitPoint(x: 1, y: 1)

    var body: some View {
        LinearGradient(colors: colors, startPoint: start, endPoint: end)
            .onAppear {
                withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                    start = UnitPoint(x: 1, y: 0)
                    end = UnitPoint(x: 0, y: 1)
                }
            }
    }
}
