import Foundation
@preconcurrency import EventKit
import Combine
import CoreGraphics

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

struct CalendarDisplayOption: Identifiable {
    let id: String
    let title: String
    let sourceID: String
    let sourceTitle: String
    let color: CGColor
    let type: EKCalendarType
}

struct CalendarSourceGroup: Identifiable {
    let id: String
    let title: String
    let calendars: [CalendarDisplayOption]
}

@MainActor
final class CalendarManager: ObservableObject {
    static let shared = CalendarManager()

    @Published var todayEvents: [EKEvent] = []
    @Published var nextEvent: EKEvent?
    @Published var hasAccess: Bool = false
    @Published var authorizationStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @Published var displayedMonthStart: Date = startOfMonth(for: Date()) {
        didSet { prefetchDatesWithEventsIfNeeded() }
    }
    @Published var selectedDate: Date = Date()
    @Published var selectedDateEvents: [EKEvent] = []
    @Published var upcomingWeekEvents: [(date: Date, events: [EKEvent])] = []
    @Published var calendarSourceGroups: [CalendarSourceGroup] = []
    @Published var hideBirthdays: Bool = UserDefaults.standard.bool(forKey: "calendar.hideBirthdays") {
        didSet {
            UserDefaults.standard.set(hideBirthdays, forKey: "calendar.hideBirthdays")
            refreshEventsAfterPreferenceChange()
        }
    }
    @Published var hideHolidays: Bool = UserDefaults.standard.bool(forKey: "calendar.hideHolidays") {
        didSet {
            UserDefaults.standard.set(hideHolidays, forKey: "calendar.hideHolidays")
            refreshEventsAfterPreferenceChange()
        }
    }
    @Published var collapseDuplicates: Bool = UserDefaults.standard.object(forKey: "calendar.collapseDuplicates") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(collapseDuplicates, forKey: "calendar.collapseDuplicates")
            refreshEventsAfterPreferenceChange()
        }
    }

    private let store = EKEventStore()
    private var refreshToken: ModuleRefreshToken?
    private var preEventTimer: Timer?
    private let calendarQueue = DispatchQueue(label: "superisland.calendar", qos: .userInitiated)
    private var isObservingStoreChanges = false
    private let enabledCalendarIDsKey = "calendar.enabledCalendarIDs"
    @Published var datesWithEvents: Set<Date> = []

    var preEventMinutes: Int {
        get { UserDefaults.standard.integer(forKey: "calendar.preEventMinutes").nonZero ?? 10 }
        set { UserDefaults.standard.set(newValue, forKey: "calendar.preEventMinutes") }
    }

    var lookaheadDays: Int {
        get { UserDefaults.standard.integer(forKey: "calendar.lookaheadDays").nonZero ?? 7 }
        set {
            UserDefaults.standard.set(max(1, min(30, newValue)), forKey: "calendar.lookaheadDays")
            fetchUpcomingWeekEvents()
        }
    }

    private init() {
        refreshAccessStatus()
    }

    // MARK: - Access

    func refreshAccessStatus() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        hasAccess = Self.isAuthorized(authorizationStatus)
        if hasAccess {
            reloadCalendars()
            fetchTodayEvents()
            registerRefresh()
            observeStoreChanges()
            prefetchDatesWithEventsIfNeeded()
        } else {
            clearEvents()
            stopRefresh()
        }
    }

    func requestAccess() {
        Task {
            do {
                let granted = try await store.requestFullAccessToEvents()
                await MainActor.run {
                    hasAccess = granted
                    authorizationStatus = EKEventStore.authorizationStatus(for: .event)
                    if granted {
                        reloadCalendars()
                        fetchTodayEvents()
                        registerRefresh()
                        observeStoreChanges()
                        prefetchDatesWithEventsIfNeeded()
                    }
                }
            } catch {
                await MainActor.run {
                    authorizationStatus = EKEventStore.authorizationStatus(for: .event)
                    hasAccess = Self.isAuthorized(authorizationStatus)
                }
                print("Calendar access error: \(error)")
            }
        }
    }

    func openCalendarSettings() {
        PermissionsManager.shared.openCalendarSettings()
    }

    private static func isAuthorized(_ status: EKAuthorizationStatus) -> Bool {
        switch status {
        case .fullAccess, .authorized:
            return true
        default:
            return false
        }
    }

    // MARK: - Calendar Sources

    var hasCustomCalendarSelection: Bool {
        UserDefaults.standard.object(forKey: enabledCalendarIDsKey) != nil
    }

    var enabledCalendarIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: enabledCalendarIDsKey) ?? [])
    }

    func isCalendarEnabled(_ calendarID: String) -> Bool {
        guard hasCustomCalendarSelection else { return true }
        return enabledCalendarIDs.contains(calendarID)
    }

    func setCalendar(_ calendarID: String, enabled: Bool) {
        var selectedIDs = hasCustomCalendarSelection ? enabledCalendarIDs : Set(allCalendarIDs)
        if enabled {
            selectedIDs.insert(calendarID)
        } else {
            selectedIDs.remove(calendarID)
        }

        UserDefaults.standard.set(allCalendarIDs.filter { selectedIDs.contains($0) }, forKey: enabledCalendarIDsKey)
        refreshEventsAfterPreferenceChange()
    }

    func hideCalendar(for event: EKEvent) {
        guard let calendar = event.calendar else { return }
        setCalendar(calendar.calendarIdentifier, enabled: false)
    }

    func reloadCalendars() {
        guard hasAccess else {
            calendarSourceGroups = []
            return
        }

        let grouped = Dictionary(grouping: store.calendars(for: .event)) { calendar in
            calendar.source.sourceIdentifier
        }

        calendarSourceGroups = grouped.map { sourceID, calendars in
            let sortedCalendars = calendars.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            let sourceTitle = sortedCalendars.first?.source.title ?? "Calendars"
            return CalendarSourceGroup(
                id: sourceID,
                title: sourceTitle,
                calendars: sortedCalendars.map { calendar in
                    CalendarDisplayOption(
                        id: calendar.calendarIdentifier,
                        title: calendar.title,
                        sourceID: sourceID,
                        sourceTitle: sourceTitle,
                        color: calendar.cgColor,
                        type: calendar.type
                    )
                }
            )
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var allCalendarIDs: [String] {
        calendarSourceGroups.flatMap { $0.calendars.map(\.id) }
    }

    // MARK: - Fetching

    func fetchTodayEvents() {
        guard hasAccess else { return }

        let cal = Foundation.Calendar.current
        let startOfDay = cal.startOfDay(for: Date())
        let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay)!
        let predicate = store.predicateForEvents(withStart: startOfDay, end: endOfDay, calendars: nil)
        let storeRef = store

        calendarQueue.async { [weak self] in
            let events = storeRef.events(matching: predicate).sorted { $0.startDate < $1.startDate }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let visibleEvents = self.visibleEvents(from: events)
                if !self.sameEvents(self.todayEvents, visibleEvents) {
                    self.todayEvents = visibleEvents
                }
                self.nextEvent = visibleEvents.first { $0.startDate > Date() }
                self.schedulePreEventNotification()
                self.fetchEventsForSelectedDate()
                self.fetchUpcomingWeekEvents()
            }
        }
    }

    // MARK: - Pre-Event Timer

    private func schedulePreEventNotification() {
        preEventTimer?.invalidate()

        guard let next = nextEvent else { return }
        let triggerDate = next.startDate.addingTimeInterval(-Double(preEventMinutes * 60))
        let interval = triggerDate.timeIntervalSinceNow

        guard interval > 0 else {
            // Event is within the notification window
            if next.startDate.timeIntervalSinceNow > 0 {
                AppState.shared.showHUD(module: .calendar, autoDismiss: false)
            }
            return
        }

        preEventTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.fetchTodayEvents()
                AppState.shared.showHUD(module: .calendar, autoDismiss: false)
            }
        }
        preEventTimer?.tolerance = min(30, max(1, interval * 0.05))
    }

    // MARK: - Refresh

    private func registerRefresh() {
        guard refreshToken == nil else { return }

        refreshToken = ModuleRefreshScheduler.shared.register(
            id: "calendar.refresh",
            name: "Calendar fallback refresh",
            module: .builtIn(.calendar),
            policy: .interval(600, tolerance: 120),
            enabled: { AppState.shared.calendarEnabled }
        ) { [weak self] in
            self?.fetchTodayEvents()
        }
    }

    private func observeStoreChanges() {
        guard !isObservingStoreChanges else { return }
        isObservingStoreChanges = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(dayChanged),
            name: .NSCalendarDayChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(eventStoreChanged),
            name: .EKEventStoreChanged,
            object: store
        )
    }

    private func stopRefresh() {
        ModuleRefreshScheduler.shared.unregister(refreshToken)
        refreshToken = nil
        NotificationCenter.default.removeObserver(self, name: .NSCalendarDayChanged, object: nil)
        NotificationCenter.default.removeObserver(self, name: .EKEventStoreChanged, object: store)
        isObservingStoreChanges = false
    }

    @objc private func dayChanged() {
        fetchTodayEvents()
    }

    @objc private func eventStoreChanged() {
        fetchTodayEvents()
        prefetchDatesWithEventsIfNeeded()
    }

    // MARK: - Helpers

    func showPreviousMonth() {
        changeDisplayedMonth(by: -1)
    }

    func showNextMonth() {
        changeDisplayedMonth(by: 1)
    }

    func resetDisplayedMonthToCurrent() {
        displayedMonthStart = Self.startOfMonth(for: Date())
    }

    var nextEventCountdown: String? {
        guard let next = nextEvent else { return nil }
        let interval = next.startDate.timeIntervalSinceNow
        guard interval > 0 else { return "now" }

        let minutes = Int(interval / 60)
        if minutes < 60 {
            return "in \(minutes) min"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return "in \(hours)h \(remainingMinutes)m"
    }

    func joinURL(for event: EKEvent) -> URL? {
        // Check notes and location for meeting URLs
        let searchTexts = [event.notes, event.location].compactMap { $0 }
        let patterns = [
            "https://[\\w.-]+\\.zoom\\.us/[\\w/?=&-]+",
            "https://meet\\.google\\.com/[\\w-]+",
            "https://teams\\.microsoft\\.com/[\\w/?=&-]+",
            "https?://[^\\s<>]+"
        ]

        for text in searchTexts {
            for pattern in patterns {
                if let range = text.range(of: pattern, options: .regularExpression) {
                    return URL(string: String(text[range]))
                }
            }
        }
        return nil
    }

    func selectDate(_ date: Date) {
        selectedDate = date
        fetchEventsForSelectedDate()
    }

    func fetchEventsForSelectedDate() {
        guard hasAccess else { return }
        let cal = Foundation.Calendar.current
        let startOfDay = cal.startOfDay(for: selectedDate)
        let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay)!
        let predicate = store.predicateForEvents(withStart: startOfDay, end: endOfDay, calendars: nil)
        let storeRef = store

        calendarQueue.async { [weak self] in
            let events = storeRef.events(matching: predicate).sorted { $0.startDate < $1.startDate }
            DispatchQueue.main.async { [weak self] in
                self?.selectedDateEvents = self?.visibleEvents(from: events) ?? []
            }
        }
    }

    func fetchUpcomingWeekEvents() {
        guard hasAccess else { return }
        let cal = Foundation.Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!
        let weekEnd = cal.date(byAdding: .day, value: lookaheadDays, to: tomorrow)!
        let predicate = store.predicateForEvents(withStart: tomorrow, end: weekEnd, calendars: nil)
        let storeRef = store

        calendarQueue.async { [weak self] in
            let allEvents = storeRef.events(matching: predicate).sorted { $0.startDate < $1.startDate }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let visibleEvents = self.visibleEvents(from: allEvents)
                var grouped: [(date: Date, events: [EKEvent])] = []
                var currentDay: Date?
                var currentEvents: [EKEvent] = []

                for event in visibleEvents {
                    let day = cal.startOfDay(for: event.startDate)
                    if day != currentDay {
                        if let prev = currentDay, !currentEvents.isEmpty {
                            grouped.append((date: prev, events: currentEvents))
                        }
                        currentDay = day
                        currentEvents = [event]
                    } else {
                        currentEvents.append(event)
                    }
                }
                if let last = currentDay, !currentEvents.isEmpty {
                    grouped.append((date: last, events: currentEvents))
                }

                self.upcomingWeekEvents = grouped
                self.prefetchDatesWithEventsIfNeeded()
            }
        }
    }

    func hasEvents(on date: Date) -> Bool {
        let startOfDay = Calendar.current.startOfDay(for: date)
        return datesWithEvents.contains(startOfDay)
    }

    func prefetchDatesWithEventsIfNeeded() {
        guard hasAccess else { return }
        let cal = Calendar.current
        // Fetch a 9-week window centered on the displayed month to cover all calendar grid cells.
        let rangeStart = cal.date(byAdding: .day, value: -14, to: displayedMonthStart)!
        let rangeEnd = cal.date(byAdding: .day, value: 49, to: displayedMonthStart)!
        let predicate = store.predicateForEvents(withStart: rangeStart, end: rangeEnd, calendars: nil)
        let storeRef = store

        calendarQueue.async { [weak self] in
            let events = storeRef.events(matching: predicate)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var dates = Set<Date>()
                for event in self.visibleEvents(from: events) {
                    dates.insert(cal.startOfDay(for: event.startDate))
                }
                self.datesWithEvents = dates
            }
        }
    }

    private func refreshEventsAfterPreferenceChange() {
        guard hasAccess else { return }
        fetchTodayEvents()
        fetchEventsForSelectedDate()
        fetchUpcomingWeekEvents()
        prefetchDatesWithEventsIfNeeded()
    }

    private func clearEvents() {
        calendarSourceGroups = []
        todayEvents = []
        nextEvent = nil
        selectedDateEvents = []
        upcomingWeekEvents = []
        datesWithEvents = []
        preEventTimer?.invalidate()
        preEventTimer = nil
    }

    private func visibleEvents(from events: [EKEvent]) -> [EKEvent] {
        let filtered = events.filter { event in
            guard let calendar = event.calendar else { return false }
            guard isCalendarEnabled(calendar.calendarIdentifier) else { return false }
            if hideBirthdays, isBirthdayCalendar(calendar) { return false }
            if hideHolidays, isHolidayCalendar(calendar) { return false }
            return true
        }

        let events = collapseDuplicates ? collapseDuplicateEvents(filtered) : filtered
        return events.sorted { $0.startDate < $1.startDate }
    }

    private func isBirthdayCalendar(_ calendar: EKCalendar) -> Bool {
        calendar.type == .birthday || calendar.title.localizedCaseInsensitiveContains("birthday")
    }

    private func isHolidayCalendar(_ calendar: EKCalendar) -> Bool {
        let calendarTitle = calendar.title.lowercased()
        let sourceTitle = calendar.source.title.lowercased()
        return calendarTitle.contains("holiday") || sourceTitle.contains("holiday")
    }

    private func collapseDuplicateEvents(_ events: [EKEvent]) -> [EKEvent] {
        var collapsed: [EKEvent] = []
        for event in events {
            guard !collapsed.contains(where: { isDuplicateEvent($0, event) }) else { continue }
            collapsed.append(event)
        }
        return collapsed
    }

    private func isDuplicateEvent(_ lhs: EKEvent, _ rhs: EKEvent) -> Bool {
        guard normalizedEventTitle(lhs) == normalizedEventTitle(rhs),
              lhs.startDate == rhs.startDate,
              lhs.endDate == rhs.endDate,
              lhs.isAllDay == rhs.isAllDay else {
            return false
        }

        let leftLocation = normalizedEventLocation(lhs)
        let rightLocation = normalizedEventLocation(rhs)
        return leftLocation == rightLocation || leftLocation.isEmpty || rightLocation.isEmpty
    }

    private func normalizedEventTitle(_ event: EKEvent) -> String {
        (event.title ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func normalizedEventLocation(_ event: EKEvent) -> String {
        (event.location ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func changeDisplayedMonth(by offset: Int) {
        let calendar = Foundation.Calendar.current
        if let updated = calendar.date(byAdding: .month, value: offset, to: displayedMonthStart) {
            displayedMonthStart = Self.startOfMonth(for: updated)
        }
    }

    private static func startOfMonth(for date: Date) -> Date {
        let calendar = Foundation.Calendar.current
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? date
    }

    private func sameEvents(_ lhs: [EKEvent], _ rhs: [EKEvent]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            left.eventIdentifier == right.eventIdentifier
                && left.title == right.title
                && left.startDate == right.startDate
                && left.endDate == right.endDate
        }
    }

    deinit {
        let token = refreshToken
        Task { @MainActor in
            ModuleRefreshScheduler.shared.unregister(token)
        }
        preEventTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
}
