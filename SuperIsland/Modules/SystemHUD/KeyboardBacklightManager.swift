import Foundation
import IOKit
import Combine

final class KeyboardBacklightManager: ObservableObject {
    static let shared = KeyboardBacklightManager()

    @Published var brightness: Float = 0.5

    private var refreshToken: ModuleRefreshToken?
    private var connect: io_connect_t = 0
    private var serviceInitialized = false

    private init() {
        setupService()
        if serviceInitialized {
            updateBrightness()
            startPolling()
        }
    }

    // MARK: - IOKit Service Setup

    private func setupService() {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleLMUController")
        )

        guard service != 0 else { return }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connect)
        IOObjectRelease(service)

        serviceInitialized = result == kIOReturnSuccess
    }

    // MARK: - Reading

    private func updateBrightness() {
        guard serviceInitialized else { return }

        let inputCount: UInt32 = 1
        var input: [UInt64] = [0]
        var outputCount: UInt32 = 1
        var output: [UInt64] = [0]

        let result = IOConnectCallScalarMethod(
            connect,
            1, // getKeyboardBacklightBrightness
            &input, inputCount,
            &output, &outputCount
        )

        if result == kIOReturnSuccess {
            let rawValue = Float(output[0]) / 0xFFF // Max value
            DispatchQueue.main.async {
                self.brightness = rawValue
            }
        }
    }

    // MARK: - Polling

    private func startPolling() {
        Task { @MainActor [weak self] in
            self?.refreshToken = ModuleRefreshScheduler.shared.register(
                id: "volume.keyboardBacklight",
                name: "Keyboard backlight refresh",
                module: .builtIn(.volumeHUD),
                policy: .visibleOnly(2, tolerance: 0.5),
                enabled: { AppState.shared.volumeHUDEnabled }
            ) { [weak self] in
                self?.updateBrightness()
            }
        }
    }

    // MARK: - Control

    func setBrightness(_ newBrightness: Float) {
        guard serviceInitialized else { return }

        let rawValue = UInt64(max(0, min(1, newBrightness)) * Float(0xFFF))
        let inputCount: UInt32 = 2
        var input: [UInt64] = [0, rawValue]
        var outputCount: UInt32 = 1
        var output: [UInt64] = [0]

        IOConnectCallScalarMethod(
            connect,
            2, // setKeyboardBacklightBrightness
            &input, inputCount,
            &output, &outputCount
        )
    }

    // MARK: - Helpers

    var brightnessPercentage: Int {
        Int(brightness * 100)
    }

    deinit {
        let token = refreshToken
        Task { @MainActor in
            ModuleRefreshScheduler.shared.unregister(token)
        }
        if serviceInitialized {
            IOServiceClose(connect)
        }
    }
}
