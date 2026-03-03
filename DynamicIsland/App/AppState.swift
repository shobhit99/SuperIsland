import Combine
import SwiftUI
import AppKit

// MARK: - Island State
enum IslandState: Equatable {
    case compact
    case expanded
    case fullExpanded
}

// MARK: - Module Type
enum ModuleType: String, CaseIterable, Identifiable {
    case nowPlaying
    case volumeHUD
    case brightnessHUD
    case battery
    case connectivity
    case calendar
    case weather
    case notifications
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nowPlaying: return "Now Playing"
        case .volumeHUD: return "Volume"
        case .brightnessHUD: return "Brightness"
        case .battery: return "Battery"
        case .connectivity: return "Connectivity"
        case .calendar: return "Calendar"
        case .weather: return "Weather"
        case .notifications: return "Notifications"
        }
    }

    var iconName: String {
        switch self {
        case .nowPlaying: return "music.note"
        case .volumeHUD: return "speaker.wave.2.fill"
        case .brightnessHUD: return "sun.max.fill"
        case .battery: return "battery.100"
        case .connectivity: return "wifi"
        case .calendar: return "calendar"
        case .weather: return "cloud.sun.fill"
        case .notifications: return "bell.fill"
        }
    }
}

// MARK: - App State
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var currentState: IslandState = .compact {
        didSet {
            handleStateTransition(from: oldValue, to: currentState)
        }
    }
    @Published var activeModule: ModuleType? = nil
    @Published var previousModule: ModuleType? = nil
    @Published var isHovering: Bool = false
    // Module enabled states (persisted via UserDefaults)
    @AppStorage("module.nowPlaying.enabled") var nowPlayingEnabled = true
    @AppStorage("module.volumeHUD.enabled") var volumeHUDEnabled = true
    @AppStorage("module.brightnessHUD.enabled") var brightnessHUDEnabled = true
    @AppStorage("module.battery.enabled") var batteryEnabled = true
    @AppStorage("module.connectivity.enabled") var connectivityEnabled = true
    @AppStorage("module.calendar.enabled") var calendarEnabled = true
    @AppStorage("module.weather.enabled") var weatherEnabled = true
    @AppStorage("module.notifications.enabled") var notificationsEnabled = true

    // Appearance settings
    @AppStorage("appearance.cornerRadius") var cornerRadius: Double = 18.0
    @AppStorage("appearance.idleOpacity") var idleOpacity: Double = 1.0
    @AppStorage("appearance.animationSpeed") var animationSpeed: Double = 1.0

    // General settings
    @AppStorage("general.showMenuBarIcon") var showMenuBarIcon = true
    @AppStorage("general.showOnAllSpaces") var showOnAllSpaces = true
    @AppStorage("general.launchAtLogin") var launchAtLogin = false
    @AppStorage("general.expandedAutoDismissDelay") var expandedAutoDismissDelay: Double = 2.0

    private var autoDismissWorkItem: DispatchWorkItem?
    private var fullExpandedCollapseWorkItem: DispatchWorkItem?
    private init() {}

    // MARK: - State Transitions

    func toggleExpansion() {
        switch currentState {
        case .compact:
            withAnimation(Constants.compactToExpanded) {
                currentState = .expanded
            }
        case .expanded:
            withAnimation(Constants.expandedToFull) {
                currentState = .fullExpanded
            }
        case .fullExpanded:
            dismiss()
        }
    }

    func expand() {
        guard currentState == .compact else { return }
        withAnimation(Constants.compactToExpanded) {
            currentState = .expanded
        }
    }

    func fullyExpand() {
        withAnimation(Constants.expandedToFull) {
            currentState = .fullExpanded
        }
    }

    func dismiss() {
        cancelAutoDismiss()
        cancelFullExpandedCollapse()
        withAnimation(Constants.expandedToCompact) {
            currentState = .compact
        }
    }

    func collapseToExpanded() {
        cancelFullExpandedCollapse()
        withAnimation(Constants.expandedToFull) {
            currentState = .expanded
        }
    }

    // MARK: - HUD Management

    func showHUD(module: ModuleType, autoDismiss: Bool = true) {
        guard isModuleEnabled(module) else { return }

        cancelAutoDismiss()

        withAnimation(Constants.hudAppear) {
            activeModule = module
            if currentState == .compact {
                currentState = .expanded
            }
        }

        if autoDismiss {
            scheduleAutoDismiss()
        } else {
            cancelAutoDismiss()
        }
    }

    func scheduleAutoDismiss() {
        cancelAutoDismiss()
        let delay = expandedAutoDismissDelay
        guard delay > 0 else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.dismiss()
        }
        autoDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: workItem
        )
    }

    func cancelAutoDismiss() {
        autoDismissWorkItem?.cancel()
        autoDismissWorkItem = nil
    }

    func scheduleFullExpandedCollapse() {
        cancelFullExpandedCollapse()
        let delay = expandedAutoDismissDelay
        guard delay > 0 else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.currentState == .fullExpanded, !self.isHovering else { return }
            self.collapseToExpanded()
        }
        fullExpandedCollapseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func cancelFullExpandedCollapse() {
        fullExpandedCollapseWorkItem?.cancel()
        fullExpandedCollapseWorkItem = nil
    }

    private func handleStateTransition(from oldValue: IslandState, to newValue: IslandState) {
        guard oldValue != newValue else { return }

        switch newValue {
        case .expanded:
            cancelFullExpandedCollapse()
            scheduleAutoDismiss()
        case .compact, .fullExpanded:
            cancelAutoDismiss()
            if newValue == .compact {
                cancelFullExpandedCollapse()
            }
        }
    }

    // MARK: - Module Cycling

    func cycleModule(forward: Bool) {
        let enabledModules = ModuleType.allCases.filter { isModuleEnabled($0) }
        guard !enabledModules.isEmpty else { return }

        if let current = activeModule, let index = enabledModules.firstIndex(of: current) {
            let nextIndex = forward
                ? enabledModules.index(after: index) % enabledModules.count
                : (index - 1 + enabledModules.count) % enabledModules.count
            withAnimation(Constants.contentSwap) {
                activeModule = enabledModules[nextIndex]
            }
        } else {
            withAnimation(Constants.contentSwap) {
                activeModule = enabledModules.first
            }
        }
    }

    func setActiveModule(_ module: ModuleType) {
        guard isModuleEnabled(module) else { return }
        withAnimation(Constants.contentSwap) {
            previousModule = activeModule
            activeModule = module
        }
    }

    // MARK: - Module Status

    func isModuleEnabled(_ module: ModuleType) -> Bool {
        switch module {
        case .nowPlaying: return nowPlayingEnabled
        case .volumeHUD: return volumeHUDEnabled
        case .brightnessHUD: return brightnessHUDEnabled
        case .battery: return batteryEnabled
        case .connectivity: return connectivityEnabled
        case .calendar: return calendarEnabled
        case .weather: return weatherEnabled
        case .notifications: return notificationsEnabled
        }
    }

    // MARK: - Size Helpers

    var currentSize: CGSize {
        switch currentState {
        case .compact:
            return compactIslandMetrics?.size ?? Constants.compactSize
        case .expanded: return Constants.expandedSize
        case .fullExpanded: return Constants.fullExpandedSize
        }
    }

    var windowSize: CGSize {
        switch currentState {
        case .compact:
            return currentSize
        case .expanded, .fullExpanded:
            return CGSize(
                width: currentSize.width + (Constants.moduleCyclerGutterWidth * 2) + 8,
                height: currentSize.height
            )
        }
    }

    var currentCornerRadius: CGFloat {
        switch currentState {
        case .compact: return currentBottomCornerRadius
        case .expanded: return Constants.expandedCornerRadius
        case .fullExpanded: return Constants.fullExpandedCornerRadius
        }
    }

    var currentTopCornerRadius: CGFloat {
        switch currentState {
        case .compact:
            return compactIslandMetrics == nil ? Constants.compactCornerRadius : 0
        case .expanded:
            return Constants.expandedCornerRadius
        case .fullExpanded:
            return Constants.fullExpandedCornerRadius
        }
    }

    var currentBottomCornerRadius: CGFloat {
        switch currentState {
        case .compact:
            return compactIslandMetrics?.bottomCornerRadius ?? Constants.compactCornerRadius
        case .expanded:
            return Constants.expandedCornerRadius
        case .fullExpanded:
            return Constants.fullExpandedCornerRadius
        }
    }

    private var compactIslandMetrics: ScreenDetector.CompactIslandMetrics? {
        guard let screen = ScreenDetector.primaryScreen else {
            return nil
        }
        return ScreenDetector.compactIslandMetrics(screen: screen)
    }
}
