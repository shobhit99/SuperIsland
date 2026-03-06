import SwiftUI
import AppKit

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
                        notificationLeadingView(notif, size: 18)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(headline(for: notif))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white.opacity(0.9))
                                .lineLimit(1)

                            if let message = message(for: notif) {
                                Text(message)
                                    .font(.system(size: 10))
                                    .foregroundColor(.white.opacity(0.7))
                                    .lineLimit(2)
                            }
                        }

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
            notificationLeadingView(notif, size: 32)

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

                Text(headline(for: notif))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                if let message = message(for: notif) {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(2)
                }
            }
        }
    }

    private func headline(for notification: IslandNotification) -> String {
        if let senderName = sanitized(notification.senderName) {
            return senderName
        }
        if let title = sanitized(notification.title) {
            return title
        }
        return notification.appName
    }

    private func message(for notification: IslandNotification) -> String? {
        let headline = headline(for: notification)
        if let preview = sanitized(notification.previewText),
           preview.localizedCaseInsensitiveCompare(headline) != .orderedSame {
            return preview
        }
        if let body = sanitized(notification.body),
           body.localizedCaseInsensitiveCompare(headline) != .orderedSame {
            return body
        }
        return nil
    }

    private func sanitized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @ViewBuilder
    private func notificationLeadingView(_ notification: IslandNotification, size: CGFloat) -> some View {
        if let avatar = image(from: notification.avatarURL) {
            Image(nsImage: avatar)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else if let iconImage = image(from: notification.appIconURL) {
            Image(nsImage: iconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
        } else if let appIcon = appIcon(for: notification.bundleIdentifier, size: size) {
            Image(nsImage: appIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
        } else {
            Image(systemName: notification.appIcon)
                .font(.system(size: max(10, size * 0.58)))
                .foregroundColor(.white.opacity(0.85))
                .frame(width: size, height: size)
        }
    }

    private func image(from urlString: String?) -> NSImage? {
        guard let urlString = sanitized(urlString) else { return nil }
        let resolvedURL: URL?
        if urlString.hasPrefix("/") {
            resolvedURL = URL(fileURLWithPath: urlString)
        } else {
            resolvedURL = URL(string: urlString)
        }

        guard let url = resolvedURL, url.isFileURL else {
            return nil
        }

        return NSImage(contentsOf: url)
    }

    private func appIcon(for bundleIdentifier: String?, size: CGFloat) -> NSImage? {
        guard let bundleIdentifier,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }

        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        icon.size = NSSize(width: size, height: size)
        return icon
    }

    private func timeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        return "\(Int(interval / 3600))h ago"
    }
}
