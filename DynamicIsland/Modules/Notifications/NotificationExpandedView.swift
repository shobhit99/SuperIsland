import SwiftUI

struct NotificationExpandedView: View {
    @ObservedObject private var manager = NotificationManager.shared
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if manager.latestNotification == nil && manager.recentNotifications.isEmpty {
                emptyState
            } else {
                notificationContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bell.slash")
                .font(.system(size: 18))
                .foregroundColor(.white.opacity(0.4))

            Text("No Notifications")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.5))

            if appState.currentState == .fullExpanded {
                Text("Notifications from apps will appear here")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var notificationContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let notif = manager.latestNotification {
                featuredNotification(notif)
            }

            if appState.currentState == .fullExpanded && manager.recentNotifications.count > 1 {
                Divider().background(.white.opacity(0.2))

                ForEach(manager.recentNotifications.prefix(5)) { notif in
                    HStack(spacing: 8) {
                        Image(systemName: notif.appIcon)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.6))

                        Text(notif.title)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.8))
                            .lineLimit(1)

                        Spacer()

                        Text(timeAgo(notif.timestamp))
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.3))
                    }
                }

                Button(action: { manager.clearAll() }) {
                    Text("Clear All")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: 320, alignment: .leading)
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: appState.currentState == .fullExpanded && manager.recentNotifications.count > 1 ? .top : .center
        )
    }

    private func featuredNotification(_ notif: IslandNotification) -> some View {
        HStack(spacing: 10) {
            Image(systemName: notif.appIcon)
                .font(.system(size: 20))
                .foregroundColor(.white)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(notif.appName)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                    Spacer()
                    Text(timeAgo(notif.timestamp))
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }

                Text(notif.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                if !notif.body.isEmpty {
                    Text(notif.body)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(2)
                }
            }
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        return "\(Int(interval / 3600))h ago"
    }
}
