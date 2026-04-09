import Foundation
import EventKit
import Combine

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

@MainActor
final class CalendarManager: ObservableObject {
    static let shared = CalendarManager()

    @Published var todayEvents: [EKEvent] = []
    @Published var nextEvent: EKEvent?
    @Published var hasAccess: Bool = false
    @Published var displayedMonthStart: Date = startOfMonth(for: Date()) {
        didSet { prefetchDatesWithEventsIfNeeded() }
    }
    @Published var selectedDate: Date = Date()
    @Published var selectedDateEvents: [EKEvent] = []
    @Published var upcomingWeekEvents: [(date: Date, events: [EKEvent])] = []

    private let store = EKEventStore()
    private var refreshTimer: Timer?
    private var preEventTimer: Timer?
    private let calendarQueue = DispatchQueue(label: "superisland.calendar", qos: .userInitiated)
    @Published var datesWithEvents: Set<Date> = []

    var preEventMinutes: Int {
        get { UserDefaults.standard.integer(forKey: "calendar.preEventMinutes").nonZero ?? 10 }
        set { UserDefaults.standard.set(newValue, forKey: "calendar.preEventMinutes") }
    }

    private init() {
        requestAccess()
    }

    // MARK: - Access

    func requestAccess() {
        Task {
            do {
                let granted = try await store.requestFullAccessToEvents()
                await MainActor.run {
                    hasAccess = granted
                    if granted {
                        fetchTodayEvents()
                        startRefreshTimer()
                        prefetchDatesWithEventsIfNeeded()
                    }
                }
            } catch {
                print("Calendar access error: \(error)")
            }
        }
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
                self.todayEvents = events
                self.nextEvent = events.first { $0.startDate > Date() }
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
    }

    // MARK: - Refresh

    private func startRefreshTimer() {
        // Refresh every 5 minutes
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.fetchTodayEvents()
            }
        }

        // Also refresh at midnight
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(dayChanged),
            name: .NSCalendarDayChanged,
            object: nil
        )
    }

    @objc private func dayChanged() {
        fetchTodayEvents()
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
            "https://teams\\.microsoft\\.com/[\\w/?=&-]+"
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
            DispatchQueue.main.async { self?.selectedDateEvents = events }
        }
    }

    func fetchUpcomingWeekEvents() {
        guard hasAccess else { return }
        let cal = Foundation.Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!
        let weekEnd = cal.date(byAdding: .day, value: 7, to: tomorrow)!
        let predicate = store.predicateForEvents(withStart: tomorrow, end: weekEnd, calendars: nil)
        let storeRef = store

        calendarQueue.async { [weak self] in
            let allEvents = storeRef.events(matching: predicate).sorted { $0.startDate < $1.startDate }

            var grouped: [(date: Date, events: [EKEvent])] = []
            var currentDay: Date?
            var currentEvents: [EKEvent] = []

            for event in allEvents {
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

            DispatchQueue.main.async { [weak self] in
                self?.upcomingWeekEvents = grouped
                self?.prefetchDatesWithEventsIfNeeded()
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
            var dates = Set<Date>()
            for event in events {
                dates.insert(cal.startOfDay(for: event.startDate))
            }
            DispatchQueue.main.async { self?.datesWithEvents = dates }
        }
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

    deinit {
        refreshTimer?.invalidate()
        preEventTimer?.invalidate()
    }
}
