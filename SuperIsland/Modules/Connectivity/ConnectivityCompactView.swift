import SwiftUI

struct ConnectivityCompactView: View {
    @ObservedObject private var bluetooth = BluetoothManager.shared
    @ObservedObject private var wifi = WiFiManager.shared

    var body: some View {
        HStack(spacing: 6) {
            if let device = bluetooth.lastConnectedDevice {
                Image(systemName: device.deviceType.iconName)
                    .font(.system(size: 12))
                    .foregroundColor(.white)

                Text(device.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
            } else if let disconnectedName = bluetooth.lastDisconnectedDeviceName {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))

                Text(disconnectedName)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
                    .strikethrough()
            } else {
                Image(systemName: wifi.signalIconName)
                    .font(.system(size: 12))
                    .foregroundColor(.white)

                if let ssid = wifi.ssid {
                    Text(ssid)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
            }
        }
    }
}
