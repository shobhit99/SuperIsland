import Foundation
import EventKit
import Combine

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

final class CalendarManager: ObservableObject {
    static let shared = CalendarManager()

    @Published var todayEvents: [EKEvent] = []
    @Published var nextEvent: EKEvent?
    @Published var hasAccess: Bool = false

    private let store = EKEventStore()
    private var refreshTimer: Timer?
    private var preEventTimer: Timer?

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

        let calendar = Foundation.Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        let predicate = store.predicateForEvents(withStart: startOfDay, end: endOfDay, calendars: nil)
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }

        DispatchQueue.main.async {
            self.todayEvents = events
            self.nextEvent = events.first { $0.startDate > Date() }
            self.schedulePreEventNotification()
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
            self?.fetchTodayEvents()
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

    deinit {
        refreshTimer?.invalidate()
        preEventTimer?.invalidate()
    }
}
