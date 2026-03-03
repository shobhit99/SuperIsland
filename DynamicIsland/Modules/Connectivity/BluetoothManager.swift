import Foundation
import IOBluetooth
import Combine

struct BluetoothDeviceInfo: Identifiable {
    let id: String
    let name: String
    let isConnected: Bool
    let deviceType: BluetoothDeviceType
    let batteryLevel: Int?

    enum BluetoothDeviceType {
        case airpods
        case headphones
        case speaker
        case keyboard
        case mouse
        case trackpad
        case other

        var iconName: String {
            switch self {
            case .airpods: return "airpodspro"
            case .headphones: return "headphones"
            case .speaker: return "hifispeaker.fill"
            case .keyboard: return "keyboard"
            case .mouse: return "magicmouse"
            case .trackpad: return "rectangle.and.hand.point.up.left"
            case .other: return "wave.3.right.circle.fill"
            }
        }
    }
}

final class BluetoothManager: ObservableObject {
    static let shared = BluetoothManager()

    @Published var connectedDevices: [BluetoothDeviceInfo] = []
    @Published var lastConnectedDevice: BluetoothDeviceInfo?
    @Published var lastDisconnectedDeviceName: String?

    private var pollTimer: Timer?

    private init() {
        updateDevices()
        startMonitoring()
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        // Register for Bluetooth connection notifications
        IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))

        // Poll periodically for device changes
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.updateDevices()
        }
    }

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        DispatchQueue.main.async { [weak self] in
            self?.updateDevices()
            if let name = device.name {
                let info = BluetoothDeviceInfo(
                    id: device.addressString ?? UUID().uuidString,
                    name: name,
                    isConnected: true,
                    deviceType: Self.classifyDevice(device),
                    batteryLevel: nil
                )
                self?.lastConnectedDevice = info
                AppState.shared.showHUD(module: .connectivity)
            }
        }

        // Register for disconnect
        device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
    }

    @objc private func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        DispatchQueue.main.async { [weak self] in
            self?.lastDisconnectedDeviceName = device.name
            self?.updateDevices()
            AppState.shared.showHUD(module: .connectivity)
        }
    }

    // MARK: - Device Updates

    func updateDevices() {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return }

        let devices = paired.filter { $0.isConnected() }.compactMap { device -> BluetoothDeviceInfo? in
            guard let name = device.name else { return nil }
            return BluetoothDeviceInfo(
                id: device.addressString ?? UUID().uuidString,
                name: name,
                isConnected: true,
                deviceType: Self.classifyDevice(device),
                batteryLevel: nil
            )
        }

        DispatchQueue.main.async {
            self.connectedDevices = devices
        }
    }

    // MARK: - Device Classification

    private static func classifyDevice(_ device: IOBluetoothDevice) -> BluetoothDeviceInfo.BluetoothDeviceType {
        let name = (device.name ?? "").lowercased()

        if name.contains("airpod") { return .airpods }
        if name.contains("headphone") || name.contains("beats") { return .headphones }
        if name.contains("speaker") || name.contains("homepod") { return .speaker }
        if name.contains("keyboard") { return .keyboard }
        if name.contains("mouse") { return .mouse }
        if name.contains("trackpad") { return .trackpad }

        // Classify by device class
        let deviceClass = device.deviceClassMajor
        switch deviceClass {
        case 4: return .headphones // Audio
        case 5: return .keyboard // Peripheral
        default: return .other
        }
    }

    deinit {
        pollTimer?.invalidate()
    }
}
