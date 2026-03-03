import SwiftUI

struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color
    var speed: Double = 30.0

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var animate = false

    private var needsScrolling: Bool {
        textWidth > containerWidth
    }

    var body: some View {
        GeometryReader { geometry in
            let containerW = geometry.size.width

            ZStack(alignment: .leading) {
                if needsScrolling {
                    HStack(spacing: 40) {
                        textView
                        textView
                    }
                    .offset(x: animate ? -(textWidth + 40) : 0)
                    .onAppear {
                        containerWidth = containerW
                        startAnimation()
                    }
                    .onChange(of: text) { _, _ in
                        resetAnimation()
                    }
                } else {
                    textView
                }
            }
            .frame(width: containerW, alignment: .leading)
            .clipped()
            .onAppear {
                containerWidth = containerW
            }
        }
    }

    private var textView: some View {
        Text(text)
            .font(font)
            .foregroundColor(color)
            .fixedSize()
            .background(
                GeometryReader { geo in
                    Color.clear.onAppear {
                        textWidth = geo.size.width
                    }
                }
            )
    }

    private func startAnimation() {
        guard needsScrolling else { return }
        let duration = Double(textWidth + 40) / speed
        withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
            animate = true
        }
    }

    private func resetAnimation() {
        animate = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            startAnimation()
        }
    }
}
