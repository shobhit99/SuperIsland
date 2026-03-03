import Foundation
import CoreWLAN
import Combine

final class WiFiManager: ObservableObject {
    static let shared = WiFiManager()

    @Published var ssid: String?
    @Published var signalStrength: Int = 0
    @Published var isConnected: Bool = false

    private let client = CWWiFiClient.shared()
    private var pollTimer: Timer?

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

        // Poll periodically as backup
        pollTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.updateWiFiInfo()
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
        pollTimer?.invalidate()
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
