import SwiftUI

struct CalendarCompactView: View {
    @ObservedObject private var manager = CalendarManager.shared

    var body: some View {
        HStack(spacing: 6) {
            if let event = manager.nextEvent, let countdown = manager.nextEventCountdown {
                Text(event.title ?? "Event")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text(countdown)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.6))
            } else {
                Text("No events")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
    }
}
