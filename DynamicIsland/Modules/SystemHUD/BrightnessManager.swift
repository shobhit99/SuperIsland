import Foundation
import IOKit
import Combine

@MainActor
final class BrightnessManager: ObservableObject {
    static let shared = BrightnessManager()

    @Published var brightness: Float = 1.0
    @Published var displayName: String = "Built-in Display"

    private var pollingTimer: Timer?

    private init() {
        updateBrightness()
        startPolling()
    }

    // MARK: - Brightness Reading

    private func updateBrightness() {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect"),
            &iterator
        )

        guard result == kIOReturnSuccess else { return }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            var brightness: Float = 0
            let err = IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &brightness)
            if err == kIOReturnSuccess {
                DispatchQueue.main.async {
                    let oldBrightness = self.brightness
                    self.brightness = brightness

                    // Only show HUD if brightness actually changed
                    if abs(oldBrightness - brightness) > 0.01 {
                        AppState.shared.showHUD(module: .brightnessHUD)
                    }
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        IOObjectRelease(iterator)
    }

    // MARK: - Polling (IOKit doesn't have a great notification mechanism for brightness)

    private func startPolling() {
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateBrightness()
        }
    }

    func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    // MARK: - Brightness Control

    func setBrightness(_ newBrightness: Float) {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect"),
            &iterator
        )

        guard result == kIOReturnSuccess else { return }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            IODisplaySetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, newBrightness)
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        IOObjectRelease(iterator)
    }

    // MARK: - Helpers

    var brightnessPercentage: Int {
        Int(brightness * 100)
    }

    var brightnessIconName: String {
        if brightness < 0.25 {
            return "sun.min.fill"
        } else if brightness < 0.75 {
            return "sun.max.fill"
        } else {
            return "sun.max.fill"
        }
    }

    deinit {
        pollingTimer?.invalidate()
    }
}
