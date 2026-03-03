import SwiftUI

struct NotificationCompactView: View {
    @ObservedObject private var manager = NotificationManager.shared

    var body: some View {
        HStack(spacing: 6) {
            if let notif = manager.latestNotification {
                Image(systemName: "app.badge")
                    .font(.system(size: 12))
                    .foregroundColor(.white)

                Text(notif.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
            } else {
                Text("No notifications")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
    }
}
