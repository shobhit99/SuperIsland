import SwiftUI

struct BatteryExpandedView: View {
    @ObservedObject private var manager = BatteryManager.shared
    @EnvironmentObject var appState: AppState

    @State private var pulseOpacity: Double = 1.0

    var body: some View {
        Group {
            if appState.currentState == .fullExpanded {
                fullExpandedView
            } else {
                defaultExpandedView
            }
        }
        .opacity(manager.isLowBattery ? pulseOpacity : 1.0)
        .onAppear {
            if manager.isLowBattery {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    pulseOpacity = 0.6
                }
            }
        }
    }

    private var defaultExpandedView: some View {
        HStack(spacing: 16) {
            ZStack {
                Image(systemName: manager.batteryIconName)
                    .font(.system(size: 32))
                    .foregroundColor(batteryColor)
                    .symbolEffect(.bounce, value: manager.isCharging)

                if manager.isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.yellow)
                        .offset(y: -1)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(manager.batteryLevel)%")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Spacer()

                    Text(manager.powerSource)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                }

                batteryBar

                if !manager.timeRemaining.isEmpty {
                    Text(manager.timeRemaining)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
        }
    }

    private var fullExpandedView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    Image(systemName: manager.batteryIconName)
                        .font(.system(size: 24))
                        .foregroundColor(batteryColor)
                        .symbolEffect(.bounce, value: manager.isCharging)

                    if manager.isCharging {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.yellow)
                    }
                }

                Text("\(manager.batteryLevel)%")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(manager.powerSource)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.62))
                    if !manager.timeRemaining.isEmpty {
                        Text(manager.timeRemaining)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.58))
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 12)

            batteryBar

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 5) {
                Text("Battery Trend")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.82))

                BatteryHistorySparkline(samples: manager.batteryHistory)
                    .frame(height: 52)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var batteryBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.white.opacity(0.15))

                RoundedRectangle(cornerRadius: 4)
                    .fill(batteryColor)
                    .frame(width: geometry.size.width * CGFloat(manager.batteryLevel) / 100)
                    .animation(.easeInOut(duration: 0.5), value: manager.batteryLevel)
            }
        }
        .frame(height: 8)
    }

    private var batteryColor: Color {
        if manager.isCharging { return .green }
        if manager.batteryLevel <= 10 { return .red }
        if manager.batteryLevel <= 20 { return .yellow }
        return .white
    }
}

private struct BatteryHistorySparkline: View {
    let samples: [BatteryHistorySample]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.white.opacity(0.08))

                if samples.count >= 2 {
                    areaPath(in: proxy.size)
                        .fill(
                            LinearGradient(
                                colors: [Color.green.opacity(0.22), Color.green.opacity(0.04)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    linePath(in: proxy.size)
                        .stroke(Color.green.opacity(0.85), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))

                    Circle()
                        .fill(Color.green)
                        .frame(width: 4, height: 4)
                        .position(lastPoint(in: proxy.size))
                } else {
                    Text("Need more samples")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.45))
                }
            }
        }
    }

    private func linePath(in size: CGSize) -> Path {
        Path { path in
            for (index, sample) in samples.enumerated() {
                let point = point(for: sample, at: index, in: size)
                if index == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
        }
    }

    private func areaPath(in size: CGSize) -> Path {
        Path { path in
            guard !samples.isEmpty else { return }

            let first = point(for: samples[0], at: 0, in: size)
            path.move(to: CGPoint(x: first.x, y: size.height))

            for (index, sample) in samples.enumerated() {
                path.addLine(to: point(for: sample, at: index, in: size))
            }

            let last = point(for: samples[samples.count - 1], at: samples.count - 1, in: size)
            path.addLine(to: CGPoint(x: last.x, y: size.height))
            path.closeSubpath()
        }
    }

    private func lastPoint(in size: CGSize) -> CGPoint {
        guard let last = samples.last else { return .zero }
        return point(for: last, at: samples.count - 1, in: size)
    }

    private func point(for sample: BatteryHistorySample, at index: Int, in size: CGSize) -> CGPoint {
        let x: CGFloat
        if samples.count <= 1 {
            x = 0
        } else {
            x = size.width * CGFloat(index) / CGFloat(samples.count - 1)
        }
        let normalized = max(0, min(1, CGFloat(sample.level) / 100))
        let y = size.height - (size.height * normalized)
        return CGPoint(x: x, y: y)
    }
}
