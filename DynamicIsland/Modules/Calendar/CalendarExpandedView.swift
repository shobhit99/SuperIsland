import SwiftUI
import EventKit

struct CalendarExpandedView: View {
    @ObservedObject private var manager = CalendarManager.shared
    @EnvironmentObject var appState: AppState

    private let calendar = Foundation.Calendar.current

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    var body: some View {
        Group {
            if appState.currentState == .fullExpanded {
                fullExpandedCalendar
            } else {
                mediumExpandedSummary
            }
        }
    }

    // MARK: - Medium Expanded (Previous Behavior)

    private var mediumExpandedSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(headerDate)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Text("\(manager.todayEvents.count) events")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
            }

            Group {
                if let event = manager.nextEvent {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color(cgColor: event.calendar.cgColor))
                            .frame(width: 8, height: 8)

                        Text(event.title ?? "")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(1)

                        Spacer()

                        if let countdown = manager.nextEventCountdown {
                            Text(countdown)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.7))
                        }

                        if let url = manager.joinURL(for: event) {
                            Button(action: { NSWorkspace.shared.open(url) }) {
                                Text("Join")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.blue)
                                    .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    Text("No more events today")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
        }
    }

    // MARK: - Full Expanded (Calendar Grid + Events + Upcoming)

    private var fullExpandedCalendar: some View {
        HStack(alignment: .top, spacing: 0) {
            calendarGridPanel
                .frame(maxWidth: .infinity, alignment: .topLeading)

            panelDivider

            eventsPanel
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 12)

            panelDivider

            upcomingPanel
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.leading, 12)
        }
    }

    private var panelDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 1)
            .padding(.vertical, 4)
    }

    // MARK: - Calendar Grid (Left)

    private var calendarGridPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                monthButton(icon: "chevron.left") {
                    manager.showPreviousMonth()
                }

                Text(monthTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)

                Spacer(minLength: 4)

                if !isCurrentMonthVisible {
                    Button("Today") {
                        manager.resetDisplayedMonthToCurrent()
                        manager.selectDate(Date())
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.82))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Capsule())
                }

                monthButton(icon: "chevron.right") {
                    manager.showNextMonth()
                }
            }

            LazyVGrid(columns: dayColumns, spacing: 3) {
                ForEach(Array(orderedWeekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: dayColumns, spacing: 3) {
                ForEach(Array(gridDays.enumerated()), id: \.offset) { _, day in
                    if let date = day {
                        dayCell(for: date)
                    } else {
                        Color.clear
                            .frame(height: 22)
                    }
                }
            }
        }
    }

    // MARK: - Events Panel (Right)

    private var eventsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(selectedDateTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                Text(eventCountLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.45))
            }
            .padding(.bottom, 8)

            if manager.selectedDateEvents.isEmpty {
                Spacer()
                Text("No events")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(manager.selectedDateEvents.enumerated()), id: \.offset) { _, event in
                            calendarEventRow(event)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Upcoming Panel (Right)

    private var upcomingPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Upcoming")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .padding(.bottom, 8)

            if manager.upcomingWeekEvents.isEmpty {
                Spacer()
                Text("Nothing this week")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(manager.upcomingWeekEvents.enumerated()), id: \.offset) { _, group in
                            upcomingDaySection(date: group.date, events: group.events)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func upcomingDaySection(date: Date, events: [EKEvent]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(upcomingDayLabel(for: date))
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.55))

            ForEach(Array(events.prefix(3).enumerated()), id: \.offset) { _, event in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color(cgColor: event.calendar.cgColor))
                        .frame(width: 2, height: 14)

                    Text(event.title ?? "Untitled")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.78))
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    if event.isAllDay {
                        Text("All Day")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white.opacity(0.35))
                    } else {
                        Text(timeFormatter.string(from: event.startDate))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white.opacity(0.35))
                    }
                }
            }

            if events.count > 3 {
                Text("+\(events.count - 3) more")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.3))
                    .padding(.leading, 8)
            }
        }
    }

    private func upcomingDayLabel(for date: Date) -> String {
        if calendar.isDateInTomorrow(date) {
            return "Tomorrow"
        }
        return Self.upcomingDayFormatter.string(from: date)
    }

    private func calendarEventRow(_ event: EKEvent) -> some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color(cgColor: event.calendar.cgColor))
                .frame(width: 3, height: 28)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title ?? "Untitled")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.88))
                    .lineLimit(1)

                if event.isAllDay {
                    Text("All Day")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                } else {
                    Text("\(timeFormatter.string(from: event.startDate)) – \(timeFormatter.string(from: event.endDate))")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                }

                if let location = event.location, !location.isEmpty {
                    Text(location)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.35))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if let url = manager.joinURL(for: event) {
                Button { NSWorkspace.shared.open(url) } label: {
                    Image(systemName: "video.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white.opacity(0.88))
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(isEventActive(event) ? 0.06 : 0))
        )
    }

    private func isEventActive(_ event: EKEvent) -> Bool {
        let now = Date()
        return !event.isAllDay && event.startDate <= now && event.endDate > now
    }

    // MARK: - Day Cell

    private func dayCell(for date: Date) -> some View {
        let dayNumber = calendar.component(.day, from: date)
        let isToday = calendar.isDateInToday(date)
        let isSelected = calendar.isDate(date, inSameDayAs: manager.selectedDate)
        let isInDisplayedMonth = calendar.isDate(date, equalTo: manager.displayedMonthStart, toGranularity: .month)
        let hasEvents = manager.hasEvents(on: date)

        return Button {
            manager.selectDate(date)
        } label: {
            VStack(spacing: 2) {
                Text("\(dayNumber)")
                    .font(.system(size: 11, weight: isToday || isSelected ? .semibold : .regular))
                    .foregroundColor(dayForeground(isInDisplayedMonth: isInDisplayedMonth, isToday: isToday, isSelected: isSelected))

                Circle()
                    .fill(hasEvents && isInDisplayedMonth ? Color.white.opacity(0.4) : Color.clear)
                    .frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity, minHeight: 22)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(dayCellBackground(isToday: isToday, isSelected: isSelected))
            )
        }
        .buttonStyle(.plain)
    }

    private func dayForeground(isInDisplayedMonth: Bool, isToday: Bool, isSelected: Bool) -> Color {
        if !isInDisplayedMonth {
            return .white.opacity(0.25)
        }
        if isSelected || isToday {
            return .white
        }
        return .white.opacity(0.9)
    }

    private func dayCellBackground(isToday: Bool, isSelected: Bool) -> Color {
        if isSelected {
            return Color.blue.opacity(0.4)
        }
        if isToday {
            return Color.white.opacity(0.12)
        }
        return .clear
    }

    private func monthButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white.opacity(0.9))
                .frame(width: 20, height: 20)
                .background(Color.white.opacity(0.08))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private var selectedDateTitle: String {
        if calendar.isDateInToday(manager.selectedDate) {
            return "Today"
        }
        if calendar.isDateInYesterday(manager.selectedDate) {
            return "Yesterday"
        }
        if calendar.isDateInTomorrow(manager.selectedDate) {
            return "Tomorrow"
        }
        return Self.selectedDateFormatter.string(from: manager.selectedDate)
    }

    private var eventCountLabel: String {
        let count = manager.selectedDateEvents.count
        if count == 0 { return "" }
        return count == 1 ? "1 event" : "\(count) events"
    }

    private var monthTitle: String {
        Self.monthTitleFormatter.string(from: manager.displayedMonthStart)
    }

    private var isCurrentMonthVisible: Bool {
        calendar.isDate(manager.displayedMonthStart, equalTo: Date(), toGranularity: .month)
    }

    private var orderedWeekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let firstIndex = max(0, calendar.firstWeekday - 1)
        return Array(symbols[firstIndex...] + symbols[..<firstIndex])
    }

    private var gridDays: [Date?] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: manager.displayedMonthStart),
              let dayCount = calendar.range(of: .day, in: .month, for: monthInterval.start)?.count else {
            return []
        }

        let firstWeekdayOfMonth = calendar.component(.weekday, from: monthInterval.start)
        let leadingPadding = (firstWeekdayOfMonth - calendar.firstWeekday + 7) % 7

        var days: [Date?] = Array(repeating: nil, count: leadingPadding)
        for offset in 0..<dayCount {
            if let date = calendar.date(byAdding: .day, value: offset, to: monthInterval.start) {
                days.append(date)
            }
        }

        while days.count % 7 != 0 {
            days.append(nil)
        }
        return days
    }

    private var dayColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 0), spacing: 3), count: 7)
    }

    private var headerDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter.string(from: Date())
    }

    private static let monthTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()

    private static let selectedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, d MMM"
        return formatter
    }()

    private static let upcomingDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, d MMM"
        return formatter
    }()
}
