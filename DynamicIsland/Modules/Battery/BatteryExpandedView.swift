import SwiftUI

struct BatteryExpandedView: View {
    @ObservedObject private var manager = BatteryManager.shared
    @EnvironmentObject var appState: AppState

    @State private var pulseOpacity: Double = 1.0

    var body: some View {
        HStack(spacing: 16) {
            // Battery icon
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

                // Battery bar
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

                if !manager.timeRemaining.isEmpty {
                    Text(manager.timeRemaining)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))
                }
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

    private var batteryColor: Color {
        if manager.isCharging { return .green }
        if manager.batteryLevel <= 10 { return .red }
        if manager.batteryLevel <= 20 { return .yellow }
        return .white
    }
}
