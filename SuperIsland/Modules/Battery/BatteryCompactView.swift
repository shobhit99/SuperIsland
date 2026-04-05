import SwiftUI

struct BatteryCompactView: View {
    @ObservedObject private var manager = BatteryManager.shared

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: manager.batteryIconName)
                .font(.system(size: 14))
                .foregroundColor(batteryColor)
                .symbolEffect(.pulse, isActive: manager.isLowBattery)

            Text("\(manager.batteryLevel)%")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
        }
    }

    private var batteryColor: Color {
        if manager.isCharging { return .green }
        if manager.batteryLevel <= 10 { return .red }
        if manager.batteryLevel <= 20 { return .yellow }
        return .white
    }
}
