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

    // MARK: - Full Expanded (Month Grid + Navigation)

    private var fullExpandedCalendar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                monthButton(icon: "chevron.left") {
                    manager.showPreviousMonth()
                }

                Text(monthTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)

                Spacer(minLength: 4)

                if !isCurrentMonthVisible {
                    Button("Today") {
                        manager.resetDisplayedMonthToCurrent()
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
                            .frame(height: 16)
                    }
                }
            }
        }
    }

    private func dayCell(for date: Date) -> some View {
        let dayNumber = calendar.component(.day, from: date)
        let isToday = calendar.isDateInToday(date)
        let isInDisplayedMonth = calendar.isDate(date, equalTo: manager.displayedMonthStart, toGranularity: .month)

        return VStack(spacing: 2) {
            Text("\(dayNumber)")
                .font(.system(size: 11, weight: isToday ? .semibold : .regular))
                .foregroundColor(dayForeground(isInDisplayedMonth: isInDisplayedMonth, isToday: isToday))

            Circle()
                .fill(isToday ? Color.blue : Color.clear)
                .frame(width: 4, height: 4)
        }
        .frame(maxWidth: .infinity, minHeight: 16)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isToday ? Color.white.opacity(0.12) : Color.clear)
        )
    }

    private func dayForeground(isInDisplayedMonth: Bool, isToday: Bool) -> Color {
        if !isInDisplayedMonth {
            return .white.opacity(0.25)
        }
        if isToday {
            return .white
        }
        return .white.opacity(0.9)
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
}
