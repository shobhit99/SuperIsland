import Foundation
import SwiftUI

enum EnergyMode: String, CaseIterable, Identifiable {
    case normal
    case smart
    case lowPower

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: return "Normal"
        case .smart: return "Smart"
        case .lowPower: return "Low Power"
        }
    }

    var description: String {
        switch self {
        case .normal:
            return "Keep refresh behavior responsive."
        case .smart:
            return "Reduce background work while collapsed and restore quickly on hover."
        case .lowPower:
            return "Slow non-essential refresh and pause inactive extension work."
        }
    }
}

enum ModuleRefreshPolicy: Equatable {
    case eventDriven
    case interval(TimeInterval, tolerance: TimeInterval)
    case activeOnly(TimeInterval, tolerance: TimeInterval)
    case visibleOnly(TimeInterval, tolerance: TimeInterval)
    case manual

    var label: String {
        switch self {
        case .eventDriven:
            return "Event driven"
        case .interval(let interval, _):
            return "Every \(Self.format(interval))"
        case .activeOnly(let interval, _):
            return "Active every \(Self.format(interval))"
        case .visibleOnly(let interval, _):
            return "Visible every \(Self.format(interval))"
        case .manual:
            return "Manual"
        }
    }

    private static func format(_ interval: TimeInterval) -> String {
        if interval >= 60 {
            return "\(Int(interval / 60))m"
        }
        return "\(String(format: "%.1f", interval))s"
    }
}

struct ModuleRefreshToken: Hashable {
    fileprivate let id: String
}

struct IslandActivityState: Equatable {
    var islandState: IslandState
    var activeModule: ActiveModule?
    var fullExpandedTab: FullExpandedTab
    var isHovering: Bool
    var isAppActive: Bool
}

struct EnergyDiagnosticsSnapshot: Identifiable, Equatable {
    let id: String
    let name: String
    let moduleName: String
    let policy: String
    let status: String
    let nextFireDate: Date?
    let lastRunDate: Date?
    let lastRunDuration: TimeInterval?
    let lastError: String?
}

@MainActor
final class ModuleRefreshScheduler: ObservableObject {
    static let shared = ModuleRefreshScheduler()

    @Published private(set) var diagnostics: [EnergyDiagnosticsSnapshot] = []

    private struct Job {
        let id: String
        let name: String
        let module: ActiveModule?
        let policy: ModuleRefreshPolicy
        let enabled: @MainActor () -> Bool
        let action: @MainActor () -> Void
        var timer: Timer?
        var nextFireDate: Date?
        var lastRunDate: Date?
        var lastRunDuration: TimeInterval?
        var lastError: String?
        var status: String = "Scheduled"
    }

    private var jobs: [String: Job] = [:]
    private var recentActivity: [(date: Date, duration: TimeInterval)] = []
    private var activityState = IslandActivityState(
        islandState: .compact,
        activeModule: nil,
        fullExpandedTab: .home,
        isHovering: false,
        isAppActive: true
    )

    private init() {}

    @discardableResult
    func register(
        id: String,
        name: String,
        module: ActiveModule? = nil,
        policy: ModuleRefreshPolicy,
        enabled: @escaping @MainActor () -> Bool = { true },
        action: @escaping @MainActor () -> Void
    ) -> ModuleRefreshToken {
        unregister(id: id)

        jobs[id] = Job(
            id: id,
            name: name,
            module: module,
            policy: policy,
            enabled: enabled,
            action: action
        )
        reschedule(id: id, runIfNewlyVisible: false)
        updateDiagnostics()
        return ModuleRefreshToken(id: id)
    }

    func unregister(_ token: ModuleRefreshToken?) {
        guard let token else { return }
        unregister(id: token.id)
    }

    func unregister(id: String) {
        jobs[id]?.timer?.invalidate()
        jobs.removeValue(forKey: id)
        updateDiagnostics()
    }

    func updateActivityState(_ nextState: IslandActivityState) {
        guard activityState != nextState else { return }
        let previousState = activityState
        activityState = nextState

        for id in jobs.keys {
            let becameVisible = jobIsVisible(jobs[id]) && !jobIsVisible(jobs[id], state: previousState)
            reschedule(id: id, runIfNewlyVisible: becameVisible)
        }
        updateDiagnostics()
    }

    func refreshScheduling() {
        for id in jobs.keys {
            reschedule(id: id, runIfNewlyVisible: false)
        }
        updateDiagnostics()
    }

    func runNow(id: String) {
        guard jobs[id] != nil else { return }
        run(id: id)
    }

    private func reschedule(id: String, runIfNewlyVisible: Bool) {
        guard var job = jobs[id] else { return }

        job.timer?.invalidate()
        job.timer = nil
        job.nextFireDate = nil

        guard job.enabled() else {
            job.status = "Disabled"
            jobs[id] = job
            return
        }

        guard let schedule = effectiveSchedule(for: job) else {
            job.status = passiveStatus(for: job)
            jobs[id] = job
            return
        }

        let interval = schedule.interval
        let nextFireDate = Date().addingTimeInterval(interval)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.run(id: id)
            }
        }
        timer.tolerance = schedule.tolerance
        RunLoop.main.add(timer, forMode: .common)

        job.timer = timer
        job.nextFireDate = nextFireDate
        job.status = "Scheduled"
        jobs[id] = job

        if runIfNewlyVisible, shouldRunWhenBecomingVisible(job) {
            run(id: id)
        }
    }

    private func run(id: String) {
        guard var job = jobs[id], job.enabled() else {
            reschedule(id: id, runIfNewlyVisible: false)
            return
        }

        guard let schedule = effectiveSchedule(for: job) else {
            reschedule(id: id, runIfNewlyVisible: false)
            return
        }

        let start = Date()
        job.action()
        let duration = Date().timeIntervalSince(start)
        job.lastRunDate = start
        job.lastRunDuration = duration
        job.nextFireDate = Date().addingTimeInterval(schedule.interval)
        job.lastError = nil
        jobs[id] = job

        recordActivity(duration: duration)
        updateDiagnostics()
    }

    private func effectiveSchedule(for job: Job) -> (interval: TimeInterval, tolerance: TimeInterval)? {
        switch job.policy {
        case .eventDriven, .manual:
            return nil
        case .interval(let interval, let tolerance):
            return adjustedSchedule(interval: interval, tolerance: tolerance, module: job.module)
        case .activeOnly(let interval, let tolerance):
            guard jobIsVisible(job) || activityState.isHovering else { return nil }
            return adjustedSchedule(interval: interval, tolerance: tolerance, module: job.module)
        case .visibleOnly(let interval, let tolerance):
            guard jobIsVisible(job) else { return nil }
            return adjustedSchedule(interval: interval, tolerance: tolerance, module: job.module)
        }
    }

    private func adjustedSchedule(
        interval: TimeInterval,
        tolerance: TimeInterval,
        module: ActiveModule?
    ) -> (interval: TimeInterval, tolerance: TimeInterval) {
        let mode = AppState.shared.effectiveEnergyMode
        var adjustedInterval = max(interval, minimumInterval(for: module))
        var adjustedTolerance = max(tolerance, adjustedInterval * 0.15)

        if mode == .smart,
           activityState.islandState == .compact,
           !activityState.isHovering,
           module.map({ !AppState.shared.isModuleVisibleForRefresh($0) }) ?? true {
            adjustedInterval = max(adjustedInterval * 4, 30)
            adjustedTolerance = max(adjustedTolerance, adjustedInterval * 0.35)
        } else if mode == .lowPower {
            adjustedInterval = max(adjustedInterval * 3, 60)
            adjustedTolerance = max(adjustedTolerance, adjustedInterval * 0.4)
        }

        return (adjustedInterval, adjustedTolerance)
    }

    private func minimumInterval(for module: ActiveModule?) -> TimeInterval {
        switch module {
        case .extension_:
            return AppState.shared.effectiveEnergyMode == .lowPower ? 5 : 1
        default:
            return 1
        }
    }

    private func passiveStatus(for job: Job) -> String {
        switch job.policy {
        case .eventDriven:
            return "Event driven"
        case .manual:
            return "Manual"
        case .activeOnly, .visibleOnly:
            return job.enabled() ? "Paused" : "Disabled"
        case .interval:
            return "Paused"
        }
    }

    private func jobIsVisible(_ job: Job?) -> Bool {
        jobIsVisible(job, state: activityState)
    }

    private func jobIsVisible(_ job: Job?, state: IslandActivityState) -> Bool {
        guard let module = job?.module else {
            return state.isAppActive || state.isHovering
        }
        return AppState.shared.isModuleVisibleForRefresh(module, state: state)
    }

    private func shouldRunWhenBecomingVisible(_ job: Job) -> Bool {
        guard job.enabled() else { return false }
        guard let lastRunDate = job.lastRunDate else { return true }
        guard let schedule = effectiveSchedule(for: job) else { return false }
        return Date().timeIntervalSince(lastRunDate) >= min(schedule.interval, 5)
    }

    private func recordActivity(duration: TimeInterval) {
        let now = Date()
        recentActivity.append((now, duration))
        recentActivity.removeAll { now.timeIntervalSince($0.date) > 120 }

        let totalDuration = recentActivity.reduce(0) { $0 + $1.duration }
        if recentActivity.count >= 80 || totalDuration >= 8 {
            EnergySuggestionPresenter.shared.suggestLowPower(reason: .sustainedActivity)
            recentActivity.removeAll()
        }
    }

    private func updateDiagnostics() {
        diagnostics = jobs.values
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { job in
                EnergyDiagnosticsSnapshot(
                    id: job.id,
                    name: job.name,
                    moduleName: job.module?.displayName ?? "App",
                    policy: job.policy.label,
                    status: job.status,
                    nextFireDate: job.nextFireDate,
                    lastRunDate: job.lastRunDate,
                    lastRunDuration: job.lastRunDuration,
                    lastError: job.lastError
                )
            }
    }
}
