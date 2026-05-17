import Foundation
import CoreWLAN
import Combine

final class WiFiManager: ObservableObject {
    static let shared = WiFiManager()

    @Published var ssid: String?
    @Published var signalStrength: Int = 0
    @Published var isConnected: Bool = false

    private let client = CWWiFiClient.shared()
    private var refreshToken: ModuleRefreshToken?

    private init() {
        updateWiFiInfo()
        startMonitoring()
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        // Register for Wi-Fi events
        do {
            try client.startMonitoringEvent(with: .ssidDidChange)
            try client.startMonitoringEvent(with: .linkDidChange)
        } catch {
            print("WiFi monitoring error: \(error)")
        }

        client.delegate = self

        Task { @MainActor [weak self] in
            self?.refreshToken = ModuleRefreshScheduler.shared.register(
                id: "connectivity.wifi",
                name: "Wi-Fi fallback refresh",
                module: .builtIn(.connectivity),
                policy: .visibleOnly(30, tolerance: 10),
                enabled: { AppState.shared.connectivityEnabled }
            ) { [weak self] in
                self?.updateWiFiInfo()
            }
        }
    }

    // MARK: - Updates

    func updateWiFiInfo() {
        guard let interface = client.interface() else {
            DispatchQueue.main.async {
                self.ssid = nil
                self.isConnected = false
                self.signalStrength = 0
            }
            return
        }

        DispatchQueue.main.async {
            self.ssid = interface.ssid()
            self.isConnected = interface.ssid() != nil
            self.signalStrength = interface.rssiValue()
        }
    }

    // MARK: - Helpers

    var signalIconName: String {
        if !isConnected { return "wifi.slash" }
        let rssi = signalStrength
        if rssi > -50 { return "wifi" }
        if rssi > -60 { return "wifi" }
        if rssi > -70 { return "wifi" }
        return "wifi.exclamationmark"
    }

    var signalDescription: String {
        guard isConnected else { return "Not connected" }
        let rssi = signalStrength
        if rssi > -50 { return "Excellent signal" }
        if rssi > -60 { return "Strong signal" }
        if rssi > -70 { return "Fair signal" }
        return "Weak signal"
    }

    deinit {
        let token = refreshToken
        Task { @MainActor in
            ModuleRefreshScheduler.shared.unregister(token)
        }
    }
}

extension WiFiManager: CWEventDelegate {
    func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        updateWiFiInfo()
    }

    func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        updateWiFiInfo()
    }
}
