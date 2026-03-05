import Foundation
import IOKit.ps
import Combine
import AppKit

struct BatteryHistorySample: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let level: Int
}

struct BatteryConsumerApp: Identifiable, Equatable {
    let id: String
    let appName: String
    let impactScore: Double
    let metricLabel: String

    var formattedImpact: String {
        String(format: "%.1f %@", impactScore, metricLabel)
    }
}

@MainActor
final class BatteryManager: ObservableObject {
    static let shared = BatteryManager()

    @Published var batteryLevel: Int = 100
    @Published var isCharging: Bool = false
    @Published var isPluggedIn: Bool = false
    @Published var timeRemaining: String = ""
    @Published var powerSource: String = "Battery"
    @Published var isLowBattery: Bool = false
    @Published var cycleCount: Int = 0
    @Published var batteryHistory: [BatteryHistorySample] = []
    @Published var topBatteryConsumers: [BatteryConsumerApp] = []
    @Published var batteryInsightsUpdatedAt: Date?

    private var runLoopSource: CFRunLoopSource?
    private var hasLoadedInitialSnapshot = false
    private var historyTimer: Timer?
    private var consumerPollTimer: Timer?
    private let historySampleInterval: TimeInterval = 300
    private let maxHistorySamples = 72

    private init() {
        updateBatteryInfo()
        startMonitoring()
        startInsightsMonitoring()
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

    private func startInsightsMonitoring() {
        appendHistorySample(force: true)
        refreshTopBatteryConsumers()

        historyTimer?.invalidate()
        historyTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.appendHistorySample(force: false)
            }
        }

        consumerPollTimer?.invalidate()
        consumerPollTimer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshTopBatteryConsumers()
            }
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
            if hasLoadedInitialSnapshot && (abs(oldLevel - capacity) >= 5 || (oldLevel > 20 && capacity <= 20)) {
                AppState.shared.showHUD(module: .battery)
            }
        }

        if let charging = info[kIOPSIsChargingKey] as? Bool {
            let wasCharging = isCharging
            isCharging = charging
            if hasLoadedInitialSnapshot && charging != wasCharging {
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

        appendHistorySample(force: false)
        hasLoadedInitialSnapshot = true
    }

    private func appendHistorySample(force: Bool) {
        let now = Date()

        guard force || batteryHistory.isEmpty else {
            if let last = batteryHistory.last {
                if now.timeIntervalSince(last.timestamp) < historySampleInterval && last.level == batteryLevel {
                    return
                }
            }
            batteryHistory.append(BatteryHistorySample(timestamp: now, level: batteryLevel))
            if batteryHistory.count > maxHistorySamples {
                batteryHistory.removeFirst(batteryHistory.count - maxHistorySamples)
            }
            return
        }

        batteryHistory.append(BatteryHistorySample(timestamp: now, level: batteryLevel))
        if batteryHistory.count > maxHistorySamples {
            batteryHistory.removeFirst(batteryHistory.count - maxHistorySamples)
        }
    }

    func refreshTopBatteryConsumers() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let apps = Self.fetchTopBatteryConsumers()
            DispatchQueue.main.async {
                self.topBatteryConsumers = apps
                self.batteryInsightsUpdatedAt = Date()
            }
        }
    }

    nonisolated private static func fetchTopBatteryConsumers() -> [BatteryConsumerApp] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        task.arguments = ["-l", "1", "-o", "power", "-stats", "pid,command,power,cpu"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
        } catch {
            return fallbackRunningApps()
        }
        task.waitUntilExit()

        guard let outputData = try? pipe.fileHandleForReading.readToEnd(),
              let output = String(data: outputData, encoding: .utf8),
              !output.isEmpty
        else {
            return fallbackRunningApps()
        }

        let lines = output.components(separatedBy: .newlines)
        let headerLine = lines.first { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("PID") && trimmed.contains("COMMAND")
        }

        let headerColumns = headerLine?
            .split(whereSeparator: \.isWhitespace)
            .map(String.init) ?? []
        let trailingColumns = Array(headerColumns.suffix(2).map { $0.uppercased() })

        var powerFirst = true
        if trailingColumns.count == 2 {
            powerFirst = trailingColumns[0].contains("POWER")
        }

        let regex = try? NSRegularExpression(
            pattern: #"^\s*(\d+)\s+(.+?)\s+([0-9]+(?:\.[0-9]+)?)\s+([0-9]+(?:\.[0-9]+)?)\s*$"#,
            options: []
        )

        struct Aggregate {
            var score: Double
            var usesPower: Bool
        }

        var aggregate: [String: Aggregate] = [:]
        let regularApps = Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { $0.localizedName }
                .map { normalizeHumanAppName($0) }
        )

        for line in lines {
            guard let regex,
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line))
            else {
                continue
            }

            guard let pidRange = Range(match.range(at: 1), in: line),
                  let commandRange = Range(match.range(at: 2), in: line),
                  let firstValueRange = Range(match.range(at: 3), in: line),
                  let secondValueRange = Range(match.range(at: 4), in: line)
            else {
                continue
            }

            let pid = Int32(String(line[pidRange])) ?? 0
            if pid <= 0 { continue }

            let valueA = Double(line[firstValueRange]) ?? 0
            let valueB = Double(line[secondValueRange]) ?? 0
            let power = powerFirst ? valueA : valueB
            let cpu = powerFirst ? valueB : valueA

            let score = power > 0 ? power : cpu
            let command = String(line[commandRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let appName = resolvedAppName(pid: pid, command: command)
            guard !appName.isEmpty else { continue }
            guard regularApps.contains(appName) else { continue }

            let current = aggregate[appName] ?? Aggregate(score: 0, usesPower: false)
            aggregate[appName] = Aggregate(score: current.score + score, usesPower: current.usesPower || power > 0)
        }

        if aggregate.isEmpty {
            return fallbackRunningApps()
        }

        return aggregate
            .map { key, value in
                BatteryConsumerApp(
                    id: key,
                    appName: key,
                    impactScore: value.score,
                    metricLabel: value.usesPower ? "power" : "% CPU"
                )
            }
            .sorted { $0.impactScore > $1.impactScore }
            .prefix(3)
            .map { $0 }
    }

    nonisolated private static func resolvedAppName(pid: Int32, command: String) -> String {
        if let app = NSRunningApplication(processIdentifier: pid) {
            if let bundleID = app.bundleIdentifier?.lowercased() {
                if bundleID.hasPrefix("com.google.chrome") { return "Google Chrome" }
                if bundleID == "com.apple.music" { return "Apple Music" }
                if bundleID == "com.spotify.client" { return "Spotify" }
                if bundleID.hasPrefix("com.microsoft.vscode") { return "VS Code" }
                if bundleID.contains("cursor") { return "Cursor" }
                if bundleID == "com.apple.terminal" { return "Terminal" }
            }

            if let name = app.localizedName?.nonEmpty {
                return normalizeHumanAppName(name)
            }
        }

        return normalizedCommandName(command)
    }

    nonisolated private static func normalizeHumanAppName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("Google Chrome") { return "Google Chrome" }
        if trimmed.hasPrefix("Cursor") { return "Cursor" }
        if trimmed.hasPrefix("Visual Studio Code") { return "VS Code" }
        if trimmed.hasPrefix("Code") { return "VS Code" }
        if trimmed.hasPrefix("Spotify") { return "Spotify" }
        if trimmed.hasPrefix("Music") || trimmed == "Apple Music" { return "Apple Music" }
        if trimmed.hasSuffix(" Helper") {
            return String(trimmed.dropLast(" Helper".count))
        }
        return trimmed
    }

    nonisolated private static func normalizedCommandName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("Google Chrome") { return "Google Chrome" }
        if trimmed.hasPrefix("Cursor") { return "Cursor" }
        if trimmed.hasPrefix("Electron Helper") { return "Electron" }
        if trimmed.hasPrefix("Code Helper") { return "VS Code" }
        if trimmed.hasPrefix("node") { return "Node" }
        if trimmed.hasPrefix("zsh") { return "Terminal" }
        return normalizeHumanAppName(trimmed)
    }

    nonisolated private static func fallbackRunningApps() -> [BatteryConsumerApp] {
        let fallbackApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> String? in
                app.localizedName
                    .map { normalizeHumanAppName($0) }
                    .flatMap { $0.nonEmpty }
            }
            .uniquedPreservingOrder()
            .prefix(3)

        return fallbackApps.map { appName in
            BatteryConsumerApp(
                id: appName,
                appName: appName,
                impactScore: 0,
                metricLabel: "power"
            )
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
        historyTimer?.invalidate()
        consumerPollTimer?.invalidate()
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension Array where Element == String {
    func uniquedPreservingOrder() -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in self where !seen.contains(value) {
            seen.insert(value)
            result.append(value)
        }
        return result
    }
}
