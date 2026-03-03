import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func toggle() {
        do {
            if isEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            print("LaunchAtLogin error: \(error)")
        }
    }

    static func enable() {
        guard !isEnabled else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            print("LaunchAtLogin enable error: \(error)")
        }
    }

    static func disable() {
        guard isEnabled else { return }
        do {
            try SMAppService.mainApp.unregister()
        } catch {
            print("LaunchAtLogin disable error: \(error)")
        }
    }
}
