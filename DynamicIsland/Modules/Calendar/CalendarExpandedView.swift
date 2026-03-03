import SwiftUI
import EventKit

struct CalendarExpandedView: View {
    @ObservedObject private var manager = CalendarManager.shared
    @EnvironmentObject var appState: AppState

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Text(headerDate)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Text("\(manager.todayEvents.count) events")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
            }

            if appState.currentState == .fullExpanded {
                fullEventList
            } else {
                compactEventList
            }
        }
    }

    // MARK: - Compact Event List (expanded state, ~80pt height)

    private var compactEventList: some View {
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

    // MARK: - Full Event List

    private var fullEventList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(manager.todayEvents, id: \.eventIdentifier) { event in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(cgColor: event.calendar.cgColor))
                            .frame(width: 3, height: 32)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.title ?? "")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white)
                                .lineLimit(1)

                            HStack(spacing: 4) {
                                Text(timeFormatter.string(from: event.startDate))
                                    .font(.system(size: 10))
                                    .foregroundColor(.white.opacity(0.5))

                                if let location = event.location, !location.isEmpty {
                                    Text("·")
                                        .foregroundColor(.white.opacity(0.3))
                                    Text(location)
                                        .font(.system(size: 10))
                                        .foregroundColor(.white.opacity(0.5))
                                        .lineLimit(1)
                                }
                            }
                        }

                        Spacer()

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
                    .onTapGesture {
                        // Open event in Calendar app
                        if let url = URL(string: "ical://") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private var headerDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter.string(from: Date())
    }
}
