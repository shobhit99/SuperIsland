import Combine
import SwiftUI
import AppKit

// MARK: - Temperature Unit
enum TemperatureUnit: String {
    case celsius
    case fahrenheit
}

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
    case shelf
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
        case .shelf: return "Shelf"
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
        case .shelf: return "tray.full.fill"
        case .connectivity: return "wifi"
        case .calendar: return "calendar"
        case .weather: return "cloud.sun.fill"
        case .notifications: return "bell.fill"
        }
    }
}

enum NotchHapticIntensity: Int, CaseIterable, Identifiable {
    case off = 0
    case subtle = 1
    case medium = 2
    case strong = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .subtle: return "Subtle"
        case .medium: return "Medium"
        case .strong: return "Strong"
        }
    }

    var feedbackSequence: [(delay: TimeInterval, pattern: NSHapticFeedbackManager.FeedbackPattern)] {
        switch self {
        case .off:
            return []
        case .subtle:
            return [(delay: 0, pattern: .generic)]
        case .medium:
            return [(delay: 0, pattern: .alignment)]
        case .strong:
            return [(delay: 0, pattern: .levelChange)]
        }
    }
}

@MainActor
enum HapticFeedbackController {
    private static var pendingWorkItems: [UUID: DispatchWorkItem] = [:]

    static func play(sequence: [(delay: TimeInterval, pattern: NSHapticFeedbackManager.FeedbackPattern)], cancelPending: Bool = true) {
        guard !sequence.isEmpty else { return }

        if cancelPending {
            cancelPendingFeedback()
        }

        for feedback in sequence {
            schedule(pattern: feedback.pattern, after: feedback.delay)
        }
    }

    static func play(named type: String) {
        let soundName: String?
        let sequence: [(delay: TimeInterval, pattern: NSHapticFeedbackManager.FeedbackPattern)]

        switch type {
        case "success":
            soundName = "Glass"
            sequence = [
                (delay: 0, pattern: .alignment),
                (delay: 0.045, pattern: .generic)
            ]
        case "warning":
            soundName = "Funk"
            sequence = [
                (delay: 0, pattern: .levelChange),
                (delay: 0.05, pattern: .alignment)
            ]
        case "error":
            soundName = "Basso"
            sequence = [
                (delay: 0, pattern: .levelChange),
                (delay: 0.06, pattern: .levelChange)
            ]
        case "selection":
            soundName = "Pop"
            sequence = [(delay: 0, pattern: .generic)]
        default:
            soundName = nil
            sequence = [(delay: 0, pattern: .generic)]
        }

        play(sequence: sequence, cancelPending: false)

        if let soundName {
            NSSound(named: soundName)?.play()
        } else {
            NSSound.beep()
        }
    }

    private static func schedule(pattern: NSHapticFeedbackManager.FeedbackPattern, after delay: TimeInterval) {
        let workItemID = UUID()
        var workItem: DispatchWorkItem!
        workItem = DispatchWorkItem {
            pendingWorkItems.removeValue(forKey: workItemID)
            guard !workItem.isCancelled else { return }
            NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
        }

        pendingWorkItems[workItemID] = workItem

        if delay <= 0 {
            DispatchQueue.main.async(execute: workItem)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private static func cancelPendingFeedback() {
        pendingWorkItems.values.forEach { $0.cancel() }
        pendingWorkItems.removeAll()
    }
}

enum FullExpandedTab: Hashable, Identifiable {
    case home
    case module(ActiveModule)

    var id: String {
        switch self {
        case .home:
            return "home"
        case .module(let module):
            switch module {
            case .builtIn(let builtIn):
                return "module.\(builtIn.rawValue)"
            case .extension_(let extensionID):
                return "extension.\(extensionID)"
            }
        }
    }

    @MainActor
    var iconName: String {
        switch self {
        case .home:
            return "house.fill"
        case .module(let module):
            return module.iconName
        }
    }

    @MainActor
    var iconImage: NSImage? {
        switch self {
        case .home:
            return nil
        case .module(let module):
            return module.iconImage
        }
    }

    @MainActor
    var title: String {
        switch self {
        case .home:
            return "Home"
        case .module(let module):
            return module.displayName
        }
    }
}

// MARK: - App State
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    /// Called from didSet so the window can resize while still inside
    /// the withAnimation block. No GeometryReader exists, so the resize
    /// is invisible to SwiftUI — the surface stays centered on the notch.
    var didChangeState: ((_ from: IslandState, _ to: IslandState) -> Void)?

    @Published var currentState: IslandState = .compact {
        didSet {
            if oldValue != currentState {
                didChangeState?(oldValue, currentState)
            }
            handleStateTransition(from: oldValue, to: currentState)
        }
    }
    @Published var activeModule: ActiveModule? = nil
    @Published var previousModule: ActiveModule? = nil
    @Published var fullExpandedSelectedTab: FullExpandedTab = .home
    @Published var isHovering: Bool = false
    @Published private(set) var isShelfDragActive = false
    /// Set by IslandWindowController during overshoot animations to prevent
    /// hover-triggered dismiss from firing while the window frame is resizing.
    var suppressDismissScheduling: Bool = false
    @Published private(set) var presentationScreenFrame: NSRect = .zero
    @Published private(set) var presentationHasNotch: Bool = false
    @Published private(set) var presentationNotchRect: NSRect? = nil
    // Module enabled states (persisted via UserDefaults)
    @AppStorage("module.nowPlaying.enabled") var nowPlayingEnabled = true
    @AppStorage("module.volumeHUD.enabled") var volumeHUDEnabled = true
    @AppStorage("module.brightnessHUD.enabled") var brightnessHUDEnabled = true
    @AppStorage("module.battery.enabled") var batteryEnabled = true
    @AppStorage("module.shelf.enabled") var shelfEnabled = true
    @AppStorage("module.connectivity.enabled") var connectivityEnabled = true
    @AppStorage("module.calendar.enabled") var calendarEnabled = true
    @AppStorage("module.weather.enabled") var weatherEnabled = true
    @AppStorage("module.weather.temperatureUnit") var temperatureUnit: TemperatureUnit = .celsius
    @AppStorage("module.notifications.enabled") var notificationsEnabled = true
    @AppStorage("module.shelf.autoOpenOnDrop") var shelfAutoOpenOnDrop = true
    @AppStorage("module.shelf.defaultToShelf") var shelfDefaultToShelf = false

    // Appearance settings
    @AppStorage("appearance.cornerRadius") var cornerRadius: Double = 18.0
    @AppStorage("appearance.idleOpacity") var idleOpacity: Double = 1.0
    @AppStorage("appearance.animationSpeed") var animationSpeed: Double = 1.0

    // General settings
    @AppStorage("general.showMenuBarIcon") var showMenuBarIcon = true
    @AppStorage("general.showOnAllSpaces") var showOnAllSpaces = true
    @AppStorage("general.launchAtLogin") var launchAtLogin = false
    @AppStorage("general.showInScreenRecordings") var showInScreenRecordings = false
    @AppStorage("general.expandedAutoDismissDelay") var expandedAutoDismissDelay: Double = 1.0
    @AppStorage("general.notchHapticIntensity") var notchHapticIntensity = NotchHapticIntensity.medium.rawValue
    @AppStorage("general.lockFullExpandedInPlace") var lockFullExpandedInPlace = false
    @AppStorage("general.hideSideSlots") var hideSideSlots = false
    @AppStorage("onboarding.completed") var onboardingCompleted = false
    @AppStorage("debug.alwaysShowOnboarding") var debugAlwaysShowOnboarding = false

    private var autoDismissWorkItem: DispatchWorkItem?
    private var fullExpandedDismissWorkItem: DispatchWorkItem?
    private var hoverActivationWorkItem: DispatchWorkItem?
    private var systemEmojiInteractionWorkItem: DispatchWorkItem?
    private var systemEmojiInteractionExpiry: Date?
    private var lastNotchEntryHapticDate: Date = .distantPast
    private init() {}

    // MARK: - State Transitions

    func toggleExpansion() {
        switch currentState {
        case .compact:
            open()
        case .expanded:
            withAnimation(Constants.notchAnimation) {
                currentState = .fullExpanded
            }
        case .fullExpanded:
            dismiss()
        }
    }

    func expand() {
        guard currentState == .compact else { return }
        withAnimation(Constants.notchAnimation) {
            currentState = .expanded
        }
    }

    func open() {
        guard currentState != .fullExpanded else { return }

        prepareFullExpandedPresentation(prefersHome: currentState == .compact)
        cancelAutoDismiss()
        cancelFullExpandedDismiss()

        withAnimation(Constants.notchAnimation) {
            currentState = .fullExpanded
        }
    }

    func fullyExpand() {
        prepareFullExpandedPresentation(prefersHome: false)
        withAnimation(Constants.notchAnimation) {
            currentState = .fullExpanded
        }
    }

    func dismiss() {
        if isShelfDragActive {
            cancelAutoDismiss()
            cancelFullExpandedDismiss()
            cancelHoverActivation()
            return
        }
        if currentState == .fullExpanded, lockFullExpandedInPlace {
            cancelFullExpandedDismiss()
            return
        }
        cancelAutoDismiss()
        cancelFullExpandedDismiss()
        cancelHoverActivation()
        endSystemEmojiInteraction()
        withAnimation(Constants.notchAnimation) {
            currentState = .compact
        }
    }

    func handleHoverChange(_ hovering: Bool) {
        let wasHovering = isHovering
        isHovering = hovering

        if isShelfDragActive {
            cancelAutoDismiss()
            cancelFullExpandedDismiss()
            cancelHoverActivation()
            return
        }

        if hovering {
            if !wasHovering {
                performNotchEntryHapticIfNeeded()
            }

            cancelAutoDismiss()
            cancelFullExpandedDismiss()

            if isSystemEmojiInteractionActive {
                cancelHoverActivation()
                return
            }

            if currentState != .fullExpanded {
                scheduleHoverActivation(wasHovering: wasHovering)
            } else {
                cancelHoverActivation()
            }
        } else {
            cancelHoverActivation()

            if isSystemEmojiInteractionActive {
                return
            }

            // Don't schedule dismiss during overshoot window-resize animations —
            // onHover can glitch as tracking areas recalculate.
            guard !suppressDismissScheduling else { return }

            if currentState == .expanded {
                scheduleAutoDismiss()
            } else if currentState == .fullExpanded {
                scheduleFullExpandedDismiss()
            }
        }
    }

    // MARK: - HUD Management

    func showHUD(module: ModuleType, autoDismiss: Bool = true, autoDismissDelay: TimeInterval? = nil) {
        showHUD(module: .builtIn(module), autoDismiss: autoDismiss, autoDismissDelay: autoDismissDelay)
    }

    func showHUD(module: ActiveModule, autoDismiss: Bool = true, autoDismissDelay: TimeInterval? = nil) {
        if case .builtIn(let builtIn) = module, !isModuleEnabled(builtIn) {
            return
        }

        if shouldDirectlyOpenNotificationsOnHover(for: module) {
            presentNotificationsFullExpanded()
            return
        }

        cancelAutoDismiss()

        withAnimation(Constants.hudAppear) {
            activeModule = module
            if currentState == .compact {
                currentState = .expanded
            }
        }

        if autoDismiss {
            scheduleAutoDismiss(after: autoDismissDelay)
        } else {
            cancelAutoDismiss()
        }
    }

    func scheduleAutoDismiss(after delayOverride: TimeInterval? = nil) {
        cancelAutoDismiss()
        guard !isShelfDragActive else { return }
        guard !isSystemEmojiInteractionActive else { return }
        let delay = delayOverride ?? expandedAutoDismissDelay
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

    func scheduleFullExpandedDismiss() {
        cancelFullExpandedDismiss()
        guard !isShelfDragActive else { return }
        guard !(currentState == .fullExpanded && lockFullExpandedInPlace) else { return }
        guard !isSystemEmojiInteractionActive else { return }
        let delay = expandedAutoDismissDelay
        guard delay > 0 else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.currentState == .fullExpanded, !self.isHovering else { return }
            self.dismiss()
        }
        fullExpandedDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func cancelFullExpandedDismiss() {
        fullExpandedDismissWorkItem?.cancel()
        fullExpandedDismissWorkItem = nil
    }

    func toggleFullExpandedLock() {
        lockFullExpandedInPlace.toggle()

        if lockFullExpandedInPlace {
            cancelFullExpandedDismiss()
            return
        }

        guard currentState == .fullExpanded,
              !isHovering,
              !suppressDismissScheduling,
              !isShelfDragActive,
              !isSystemEmojiInteractionActive else {
            return
        }

        scheduleFullExpandedDismiss()
    }

    func cancelHoverActivation() {
        hoverActivationWorkItem?.cancel()
        hoverActivationWorkItem = nil
    }

    var isSystemEmojiInteractionActive: Bool {
        guard let expiry = systemEmojiInteractionExpiry else { return false }
        return expiry > Date()
    }

    func beginSystemEmojiInteraction(timeout: TimeInterval = 12) {
        cancelAutoDismiss()
        cancelFullExpandedDismiss()

        let expiry = Date().addingTimeInterval(timeout)
        systemEmojiInteractionExpiry = expiry
        systemEmojiInteractionWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.systemEmojiInteractionExpiry = nil
            self.systemEmojiInteractionWorkItem = nil

            guard !self.isHovering else { return }
            if self.currentState == .expanded {
                self.scheduleAutoDismiss()
            } else if self.currentState == .fullExpanded {
                self.scheduleFullExpandedDismiss()
            }
        }

        systemEmojiInteractionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: workItem)
    }

    func beginCompactControlInteraction(timeout: TimeInterval = 1.2) {
        beginSystemEmojiInteraction(timeout: timeout)
    }

    func endSystemEmojiInteraction() {
        systemEmojiInteractionWorkItem?.cancel()
        systemEmojiInteractionWorkItem = nil
        systemEmojiInteractionExpiry = nil
    }

    func updatePresentationContext(screen: NSScreen?) {
        guard let screen else {
            presentationScreenFrame = .zero
            presentationHasNotch = false
            presentationNotchRect = nil
            return
        }

        presentationScreenFrame = screen.frame
        presentationHasNotch = ScreenDetector.hasNotch(screen: screen)
        presentationNotchRect = ScreenDetector.notchRect(screen: screen)
    }

    private func scheduleHoverActivation(wasHovering: Bool) {
        guard !wasHovering else { return }
        guard !isSystemEmojiInteractionActive else { return }

        cancelHoverActivation()

        let startingState = currentState
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isHovering, self.currentState != .fullExpanded else { return }

            if self.shouldHoverExpandNotifications(from: startingState) {
                self.presentNotificationsFullExpanded()
                return
            }

             if startingState == .compact,
                let module = self.compactPresentationModule,
                case .extension_ = module,
                self.canPresentFullExpandedModule(module) {
                self.cancelAutoDismiss()
                self.cancelFullExpandedDismiss()
                self.previousModule = self.activeModule
                self.activeModule = module
                self.fullyExpand()
                return
            }

            self.open()
        }

        hoverActivationWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Constants.hoverPeekDelay,
            execute: workItem
        )
    }

    private func shouldHoverExpandNotifications(from startingState: IslandState) -> Bool {
        guard startingState == .compact || startingState == .expanded,
              activeBuiltInModule == .notifications,
              hasFreshNotificationForHover else {
            return false
        }
        return true
    }

    private func shouldDirectlyOpenNotificationsOnHover(for module: ActiveModule) -> Bool {
        guard currentState != .fullExpanded,
              isHover,
              case .builtIn(.notifications) = module,
              hasFreshNotificationForHover else {
            return false
        }

        return true
    }

    private var hasFreshNotificationForHover: Bool {
        guard let notification = NotificationManager.shared.latestNotification else {
            return false
        }

        return Date().timeIntervalSince(notification.timestamp) <= Constants.notificationHoverFullExpandWindow
    }

    private var isHover: Bool {
        isHovering
    }

    private func handleStateTransition(from oldValue: IslandState, to newValue: IslandState) {
        guard oldValue != newValue else { return }

        switch newValue {
        case .expanded:
            cancelFullExpandedDismiss()
            if !suppressDismissScheduling && !isShelfDragActive {
                scheduleAutoDismiss()
            }
        case .compact, .fullExpanded:
            cancelAutoDismiss()
            if newValue == .compact {
                cancelFullExpandedDismiss()
            }
        }
    }

    // MARK: - Module Cycling

    func cycleModule(forward: Bool) {
        if currentState == .fullExpanded {
            cycleFullExpandedTab(forward: forward)
            return
        }

        let modules = availableModules
        guard !modules.isEmpty else { return }

        let nextModule: ActiveModule
        if let activeModule, let index = modules.firstIndex(of: activeModule) {
            let nextIndex = forward
                ? modules.index(after: index) % modules.count
                : (index - 1 + modules.count) % modules.count
            nextModule = modules[nextIndex]
        } else if forward {
            nextModule = modules[0]
        } else {
            nextModule = modules[modules.count - 1]
        }

        withAnimation(Constants.contentSwap) {
            previousModule = activeModule
            activeModule = nextModule
        }
    }

    func setActiveModule(_ module: ModuleType) {
        setActiveModule(.builtIn(module))
    }

    func setActiveModule(_ module: ActiveModule) {
        if case .builtIn(let builtIn) = module, !isModuleEnabled(builtIn) {
            return
        }
        withAnimation(Constants.contentSwap) {
            previousModule = activeModule
            activeModule = module
        }
    }

    func selectFullExpandedTab(_ tab: FullExpandedTab) {
        withAnimation(Constants.contentSwap) {
            fullExpandedSelectedTab = tab
        }

        updateShelfDefaultSelection(for: tab)

        if case .module(let module) = tab {
            setActiveModule(module)
        }
    }

    func showHomeTab() {
        withAnimation(Constants.contentSwap) {
            fullExpandedSelectedTab = .home
        }
        shelfDefaultToShelf = false
    }

    // MARK: - Module Status

    func isModuleEnabled(_ module: ModuleType) -> Bool {
        switch module {
        case .nowPlaying: return nowPlayingEnabled
        case .volumeHUD: return volumeHUDEnabled
        case .brightnessHUD: return brightnessHUDEnabled
        case .battery: return batteryEnabled
        case .shelf: return shelfEnabled
        case .connectivity: return connectivityEnabled
        case .calendar: return calendarEnabled
        case .weather: return weatherEnabled
        case .notifications: return notificationsEnabled
        }
    }

    var activeBuiltInModule: ModuleType? {
        guard case .builtIn(let module) = activeModule else {
            return nil
        }
        return module
    }

    private func isCyclableIslandModule(_ module: ModuleType) -> Bool {
        switch module {
        case .volumeHUD, .brightnessHUD, .battery:
            return false
        default:
            return true
        }
    }

    var availableModules: [ActiveModule] {
        let builtIns = ModuleType.allCases
            .filter { isCyclableIslandModule($0) && isModuleEnabled($0) }
            .map(ActiveModule.builtIn)
        return builtIns + ExtensionManager.shared.availableModules
    }

    var fullExpandedModules: [ActiveModule] {
        let builtIns = ModuleType.allCases
            .filter { isCyclableIslandModule($0) && supportsFullExpandedModule(.builtIn($0)) && isModuleEnabled($0) }
            .map(ActiveModule.builtIn)
        return builtIns + ExtensionManager.shared.availableModules.filter(supportsFullExpandedModule)
    }

    var fullExpandedTabs: [FullExpandedTab] {
        var tabs: [FullExpandedTab] = [.home]
        tabs.append(contentsOf: fullExpandedModules.map(FullExpandedTab.module))
        return tabs
    }

    var hasFullExpandedShoulderBarSpace: Bool {
        currentState == .fullExpanded && currentContentTopInset > 0 && fullExpandedShoulderGapWidth > 0
    }

    var fullExpandedShoulderGapWidth: CGFloat {
        guard currentState == .fullExpanded,
              let notch = currentNotchRect else {
            return 0
        }

        let minimumGap = notch.width + 20
        let maximumGap = max(160, currentContentSize.width * 0.42)
        return min(maximumGap, minimumGap)
    }

    var fullExpandedShoulderSectionWidth: CGFloat {
        max(0, (currentContentSize.width - fullExpandedShoulderGapWidth) / 2)
    }

    var compactPresentationModule: ActiveModule? {
        let nowPlaying = NowPlayingManager.shared
        let hasCompactMediaCandidate =
            !nowPlaying.title.isEmpty ||
            nowPlaying.albumArt != nil ||
            !nowPlaying.sourceName.isEmpty
        let mediaModule: ActiveModule? = hasCompactMediaCandidate
            ? .builtIn(.nowPlaying)
            : nil

        guard let activeModule else {
            return mediaModule
        }

        guard let mediaModule else {
            return activeModule
        }

        switch activeModule {
        case .builtIn(.nowPlaying):
            return activeModule
        case .extension_(let extensionID) where supportsMinimalCompactLayout(activeModule):
            let precedence = ExtensionManager.shared.extensionStates[extensionID]?.minimalCompactPrecedence ?? 1
            return precedence > 1 ? mediaModule : activeModule
        case .extension_:
            return activeModule
        default:
            return mediaModule
        }
    }

    var shouldUseMinimalCompactLayout: Bool {
        guard presentationHasNotch,
              !hideSideSlots,
              compactMinimalSideExpansion > 0,
              let module = compactPresentationModule else {
            return false
        }

        return supportsMinimalCompactLayout(module)
    }

    var compactMinimalCenterGapWidth: CGFloat {
        compactBaseSize.width
    }

    // MARK: - Size Helpers

    var currentSize: CGSize {
        size(for: currentState)
    }

    var currentContentSize: CGSize {
        contentSize(for: currentState)
    }

    func size(for state: IslandState) -> CGSize {
        let contentSize = self.contentSize(for: state)
        // On non-notch Macs the outward arch insets walls by the top
        // corner radius — widen the surface so the inner wall-to-wall
        // width matches the content frame.
        let archWidthBoost: CGFloat = usesOutwardTopCorners && !presentationHasNotch
            ? topCornerRadius(for: state) * 2
            : 0
        switch state {
        case .compact:
            return CGSize(
                width: contentSize.width + archWidthBoost,
                height: contentSize.height
            )
        case .expanded, .fullExpanded:
            return CGSize(
                width: contentSize.width + archWidthBoost,
                height: contentSize.height + contentTopInset(for: state)
            )
        }
    }

    /// Whether the compact view has room to show extra info (e.g. song title).
    var usesWideCompactLayout: Bool {
        !presentationHasNotch
    }

    func contentSize(for state: IslandState) -> CGSize {
        switch state {
        case .compact:
            if usesWideCompactLayout {
                return Constants.nonNotchCompactSize
            }
            let baseSize = compactBaseSize
            guard shouldUseMinimalCompactLayout else {
                return CGSize(
                    width: baseSize.width,
                    height: min(baseSize.height, Constants.compactNotchMinimumHeight)
                )
            }

            return CGSize(
                width: baseSize.width + (compactMinimalSideExpansion * 2),
                height: baseSize.height
            )
        case .expanded:
            return Constants.expandedSize
        case .fullExpanded:
            let base = Constants.fullExpandedSize
            // On non-notch Macs the toolbar is inline (no shoulder area),
            // so it eats into content height. Add space for it.
            if usesOutwardTopCorners && !presentationHasNotch {
                return CGSize(width: base.width, height: base.height + 50)
            }
            return base
        }
    }

    var windowSize: CGSize {
        windowSize(for: currentState)
    }

    func windowSize(for state: IslandState) -> CGSize {
        let islandSize = size(for: state)
        switch state {
        case .compact:
            return CGSize(
                width: islandSize.width,
                height: islandSize.height + 20
            )
        case .expanded, .fullExpanded:
            return CGSize(
                width: islandSize.width + (Constants.moduleCyclerGutterWidth * 2),
                height: islandSize.height + Constants.expandedShadowBottomPadding
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

    var currentTopLeadingCornerRadius: CGFloat {
        if shouldUseSquaredTopCorners {
            return notchedExpandedShoulderRadius
        }
        return currentTopCornerRadius
    }

    var currentTopTrailingCornerRadius: CGFloat {
        if shouldUseSquaredTopCorners {
            return notchedExpandedShoulderRadius
        }
        return currentTopCornerRadius
    }

    var currentBottomLeadingCornerRadius: CGFloat {
        currentBottomCornerRadius
    }

    var currentBottomTrailingCornerRadius: CGFloat {
        currentBottomCornerRadius
    }

    var currentTopCornerRadius: CGFloat {
        switch currentState {
        case .compact:
            return compactIslandMetrics?.bottomCornerRadius ?? Constants.compactCornerRadius
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

    var currentTopCutoutWidth: CGFloat {
        0
    }

    var currentTopCutoutDepth: CGFloat {
        0
    }

    var currentTopCutoutCornerRadius: CGFloat {
        0
    }

    var currentContentTopInset: CGFloat {
        contentTopInset(for: currentState)
    }

    var currentContentFrameHeight: CGFloat {
        currentContentSize.height
    }

    var contentHorizontalPadding: CGFloat {
        switch currentState {
        case .compact:
            return 0
        case .expanded:
            return 26
        case .fullExpanded:
            return 32
        }
    }

    var contentTopPadding: CGFloat {
        switch currentState {
        case .compact:
            return 0
        case .expanded:
            return 8
        case .fullExpanded:
            if case .extension_ = activeModule {
                return hasFullExpandedShoulderBarSpace ? 4 : 8
            }
            return hasFullExpandedShoulderBarSpace ? 4 : 12
        }
    }

    var contentBottomPadding: CGFloat {
        switch currentState {
        case .compact:
            return 0
        case .expanded:
            return 10
        case .fullExpanded:
            if case .extension_ = activeModule {
                return 4
            }
            return 14
        }
    }

    var expandedContentScale: CGFloat {
        guard currentState == .expanded, shouldUseSquaredTopCorners else {
            return 1
        }
        return 0.95
    }

    var expandedContentTopOffset: CGFloat {
        guard currentState == .expanded, shouldUseSquaredTopCorners else {
            return 0
        }
        return 4
    }

    private var compactBaseSize: CGSize {
        compactIslandMetrics?.size ?? Constants.compactSize
    }

    private var compactMinimalSideExpansion: CGFloat {
        guard let notch = presentationNotchRect,
              presentationScreenFrame != .zero else {
            return 0
        }

        let leftSideWidth = notch.minX - presentationScreenFrame.minX
        let rightSideWidth = presentationScreenFrame.maxX - notch.maxX
        let safeSideWidth = min(leftSideWidth, rightSideWidth) - Constants.compactMinimalSafeSideMargin

        guard safeSideWidth > 0 else {
            return 0
        }

        return min(Constants.compactMinimalSideExpansion, safeSideWidth)
    }

    private var compactIslandMetrics: ScreenDetector.CompactIslandMetrics? {
        guard let notch = presentationNotchRect else {
            return nil
        }

        let width = max(
            Constants.compactNotchMinimumWidth,
            notch.width - (Constants.compactNotchHorizontalInset * 2)
        )
        let height = max(
            Constants.compactNotchMinimumHeight,
            notch.height - Constants.compactNotchHeightInset
        )
        let bottomCornerRadius = min(Constants.compactNotchBottomCornerRadius, height / 2)

        return ScreenDetector.CompactIslandMetrics(
            size: CGSize(width: width, height: height),
            bottomCornerRadius: bottomCornerRadius
        )
    }

    var usesOutwardTopCorners: Bool {
        true
    }

    private var shouldUseSquaredTopCorners: Bool {
        shouldUseSquaredTopCorners(for: currentState)
    }

    private func contentTopInset(for state: IslandState) -> CGFloat {
        guard shouldUseSquaredTopCorners(for: state), let notch = currentNotchRect else {
            return 0
        }
        return notch.height + Constants.expandedNotchHeightBoost
    }

    private func topCornerRadius(for state: IslandState) -> CGFloat {
        switch state {
        case .compact:
            let base = compactIslandMetrics?.bottomCornerRadius ?? Constants.compactCornerRadius
            // Clamp to half the compact height (shape does the same internally).
            let height = contentSize(for: .compact).height
            return min(base, height / 2)
        case .expanded:
            return Constants.expandedCornerRadius
        case .fullExpanded:
            return Constants.fullExpandedCornerRadius
        }
    }

    private func shouldUseSquaredTopCorners(for state: IslandState) -> Bool {
        state != .compact && presentationHasNotch
    }

    private var notchedExpandedShoulderRadius: CGFloat {
        guard let notch = presentationNotchRect else {
            return currentTopCornerRadius
        }

        let targetRadius = (notch.height + Constants.expandedNotchHeightBoost) / 2
        return min(currentBottomCornerRadius, max(Constants.compactNotchBottomCornerRadius, targetRadius))
    }

    private var currentNotchRect: NSRect? {
        presentationNotchRect
    }

    private func performNotchEntryHapticIfNeeded() {
        guard presentationHasNotch,
              currentState == .compact,
              Date().timeIntervalSince(lastNotchEntryHapticDate) > 0.6 else {
            return
        }

        let intensity = NotchHapticIntensity(rawValue: notchHapticIntensity) ?? .medium
        guard intensity != .off else { return }

        lastNotchEntryHapticDate = Date()
        HapticFeedbackController.play(sequence: intensity.feedbackSequence)
    }

    private func prepareFullExpandedPresentation(prefersHome: Bool) {
        let nextTab: FullExpandedTab

        if shouldDefaultToShelf {
            nextTab = .module(.builtIn(.shelf))
        } else if prefersHome {
            nextTab = .home
        } else if let activeModule, supportsFullExpandedModule(activeModule) {
            nextTab = .module(activeModule)
        } else {
            nextTab = .home
        }

        if fullExpandedSelectedTab != nextTab {
            fullExpandedSelectedTab = nextTab
        }

        if case .module(let module) = nextTab {
            previousModule = activeModule
            activeModule = module
        }
    }

    private func cycleFullExpandedTab(forward: Bool) {
        let tabs = fullExpandedTabs
        guard !tabs.isEmpty else { return }

        let currentTab = tabs.contains(fullExpandedSelectedTab) ? fullExpandedSelectedTab : .home
        let currentIndex = tabs.firstIndex(of: currentTab) ?? 0
        let nextIndex = forward
            ? tabs.index(after: currentIndex) % tabs.count
            : (currentIndex - 1 + tabs.count) % tabs.count
        let nextTab = tabs[nextIndex]

        withAnimation(Constants.contentSwap) {
            fullExpandedSelectedTab = nextTab
            if case .module(let module) = nextTab {
                previousModule = activeModule
                activeModule = module
            }
        }

        updateShelfDefaultSelection(for: nextTab)
    }

    private func supportsFullExpandedModule(_ module: ActiveModule) -> Bool {
        switch module {
        case .builtIn(.nowPlaying), .builtIn(.connectivity):
            return false
        case .extension_(let extensionID):
            return ExtensionManager.shared.installed.first(where: { $0.id == extensionID })?.capabilities.fullExpanded ?? true
        default:
            return true
        }
    }

    private func supportsMinimalCompactLayout(_ module: ActiveModule) -> Bool {
        switch module {
        case .builtIn(.nowPlaying):
            return true
        case .extension_(let extensionID):
            return ExtensionManager.shared.installed.first(where: { $0.id == extensionID })?.capabilities.minimalCompact ?? false
        default:
            return false
        }
    }

    func canPresentFullExpandedModule(_ module: ActiveModule) -> Bool {
        switch module {
        case .extension_(let extensionID):
            return ExtensionManager.shared.installed.first(where: { $0.id == extensionID })?.capabilities.fullExpanded ?? false
        case .builtIn(.battery), .builtIn(.shelf):
            return true
        default:
            return fullExpandedModules.contains(module)
        }
    }

    func presentShelfAfterDrop() {
        isShelfDragActive = false
        rememberShelfAsDefault()
        guard shelfEnabled, shelfAutoOpenOnDrop else { return }

        cancelAutoDismiss()
        cancelFullExpandedDismiss()
        previousModule = activeModule
        activeModule = .builtIn(.shelf)
        fullExpandedSelectedTab = .module(.builtIn(.shelf))

        withAnimation(currentState == .compact ? Constants.notchAnimation : Constants.contentSwap) {
            currentState = .fullExpanded
        }
    }

    func beginShelfDragPresentation() {
        guard shelfEnabled else { return }

        isShelfDragActive = true
        cancelAutoDismiss()
        cancelFullExpandedDismiss()
        cancelHoverActivation()

        previousModule = activeModule
        activeModule = .builtIn(.shelf)
        fullExpandedSelectedTab = .module(.builtIn(.shelf))

        withAnimation(currentState == .compact ? Constants.notchAnimation : Constants.contentSwap) {
            currentState = .fullExpanded
        }
    }

    func endShelfDragPresentation() {
        isShelfDragActive = false

        guard !isHovering else { return }
        if currentState == .fullExpanded {
            scheduleFullExpandedDismiss()
        } else if currentState == .expanded {
            scheduleAutoDismiss()
        }
    }

    func presentNotificationsFullExpanded() {
        guard notificationsEnabled, NotificationManager.shared.latestNotification != nil else { return }

        cancelAutoDismiss()
        cancelFullExpandedDismiss()
        cancelHoverActivation()

        previousModule = activeModule
        activeModule = .builtIn(.notifications)
        fullExpandedSelectedTab = .module(.builtIn(.notifications))

        withAnimation(Constants.notchAnimation) {
            currentState = .fullExpanded
        }
    }

    func rememberShelfAsDefault() {
        guard shelfEnabled, !ShelfStore.shared.isEmpty else { return }
        shelfDefaultToShelf = true
    }

    private var shouldDefaultToShelf: Bool {
        shelfEnabled && shelfDefaultToShelf && !ShelfStore.shared.isEmpty
    }

    private func updateShelfDefaultSelection(for tab: FullExpandedTab) {
        switch tab {
        case .module(.builtIn(.shelf)):
            shelfDefaultToShelf = !ShelfStore.shared.isEmpty
        default:
            shelfDefaultToShelf = false
        }
    }

}
