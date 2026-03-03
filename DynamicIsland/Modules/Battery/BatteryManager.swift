import Foundation
import IOKit.ps
import Combine

final class BatteryManager: ObservableObject {
    static let shared = BatteryManager()

    @Published var batteryLevel: Int = 100
    @Published var isCharging: Bool = false
    @Published var isPluggedIn: Bool = false
    @Published var timeRemaining: String = ""
    @Published var powerSource: String = "Battery"
    @Published var isLowBattery: Bool = false
    @Published var cycleCount: Int = 0

    private var runLoopSource: CFRunLoopSource?

    private init() {
        updateBatteryInfo()
        startMonitoring()
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        let context = Unmanaged.passUnretained(self).toOpaque()

        runLoopSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let manager = Unmanaged<BatteryManager>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {
                manager.updateBatteryInfo()
            }
        }, context)?.takeRetainedValue()

        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    // MARK: - Battery Info

    func updateBatteryInfo() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [Any],
              let first = sources.first,
              let info = IOPSGetPowerSourceDescription(snapshot, first as CFTypeRef)?.takeUnretainedValue() as? [String: Any]
        else { return }

        if let capacity = info[kIOPSCurrentCapacityKey] as? Int {
            let oldLevel = batteryLevel
            batteryLevel = capacity
            isLowBattery = capacity <= 20

            // Trigger HUD on significant changes
            if abs(oldLevel - capacity) >= 5 || (oldLevel > 20 && capacity <= 20) {
                AppState.shared.showHUD(module: .battery)
            }
        }

        if let charging = info[kIOPSIsChargingKey] as? Bool {
            let wasCharging = isCharging
            isCharging = charging
            if charging != wasCharging {
                AppState.shared.showHUD(module: .battery)
            }
        }

        if let source = info[kIOPSPowerSourceStateKey] as? String {
            isPluggedIn = source == kIOPSACPowerValue
            powerSource = isPluggedIn ? "Power Adapter" : "Battery"
        }

        if let timeToEmpty = info[kIOPSTimeToEmptyKey] as? Int, timeToEmpty > 0 {
            let hours = timeToEmpty / 60
            let minutes = timeToEmpty % 60
            timeRemaining = hours > 0 ? "\(hours)h \(minutes)m remaining" : "\(minutes)m remaining"
        } else if let timeToFull = info[kIOPSTimeToFullChargeKey] as? Int, timeToFull > 0 {
            let hours = timeToFull / 60
            let minutes = timeToFull % 60
            timeRemaining = hours > 0 ? "\(hours)h \(minutes)m until full" : "\(minutes)m until full"
        } else {
            timeRemaining = isCharging ? "Calculating..." : ""
        }
    }

    // MARK: - Helpers

    var batteryIconName: String {
        if isCharging {
            return "battery.100.bolt"
        }
        switch batteryLevel {
        case 0..<10: return "battery.0"
        case 10..<25: return "battery.25"
        case 25..<50: return "battery.50"
        case 50..<75: return "battery.75"
        default: return "battery.100"
        }
    }

    var batteryColor: String {
        if isCharging { return "green" }
        if batteryLevel <= 10 { return "red" }
        if batteryLevel <= 20 { return "yellow" }
        return "white"
    }

    deinit {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }
}
