import SwiftUI
import AppKit

struct NotificationCompactView: View {
    @ObservedObject private var manager = NotificationManager.shared

    var body: some View {
        HStack(spacing: 6) {
            if let notif = manager.latestNotification {
                notificationLeadingView(notif, size: 14)

                Text(headline(for: notif))
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

    private func headline(for notification: IslandNotification) -> String {
        let sender = notification.senderName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !sender.isEmpty {
            return sender
        }

        let title = notification.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            return title
        }

        return notification.appName
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
                .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        } else if let appIcon = appIcon(for: notification.bundleIdentifier, size: size) {
            Image(nsImage: appIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        } else {
            Image(systemName: notification.appIcon)
                .font(.system(size: max(9, size * 0.58)))
                .foregroundColor(.white.opacity(0.9))
                .frame(width: size, height: size)
        }
    }

    private func image(from urlString: String?) -> NSImage? {
        guard let urlString = urlString?.trimmingCharacters(in: .whitespacesAndNewlines), !urlString.isEmpty else {
            return nil
        }

        let url: URL?
        if urlString.hasPrefix("/") {
            url = URL(fileURLWithPath: urlString)
        } else {
            url = URL(string: urlString)
        }

        guard let url, url.isFileURL else { return nil }
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
}
