import SwiftUI
import AppKit

struct NotificationExpandedView: View {
    @ObservedObject private var manager = NotificationManager.shared
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if manager.latestNotification == nil && manager.recentNotifications.isEmpty {
                emptyState
            } else if appState.currentState == .fullExpanded {
                fullExpandedNotificationContent
            } else {
                expandedNotificationContent
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

    private var expandedNotificationContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let latestNotification = manager.latestNotification {
                featuredNotification(latestNotification, chrome: .plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var fullExpandedNotificationContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let latestNotification = manager.latestNotification {
                featuredNotification(latestNotification, chrome: .card)
            }

            if !previousNotifications.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(previousNotifications) { notification in
                            notificationRow(notification, featured: false, chrome: .card)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()
            } else {
                Spacer(minLength: 0)
            }

            if !manager.recentNotifications.isEmpty {
                footerBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var previousNotifications: [IslandNotification] {
        Array(manager.recentNotifications.dropFirst())
    }

    private var footerBar: some View {
        HStack(spacing: 6) {
            Text("\(manager.recentNotifications.count) notification\(manager.recentNotifications.count == 1 ? "" : "s")")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.white.opacity(0.34))

            Spacer(minLength: 0)

            Button(action: { manager.clearAll() }) {
                Text("Clear All")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.58))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18, alignment: .center)
        .padding(.top, 2)
        .overlay(alignment: .top) {
            Capsule()
                .fill(.white.opacity(0.06))
                .frame(height: 1)
        }
    }

    private func featuredNotification(_ notification: IslandNotification, chrome: NotificationRowChrome) -> some View {
        notificationRow(notification, featured: true, chrome: chrome)
    }

    private func notificationRow(_ notification: IslandNotification, featured: Bool, chrome: NotificationRowChrome) -> some View {
        let shouldHandleTap = appState.currentState == .expanded || notification.tapAction != nil
        return SwipeToDismissNotificationRow(
            featured: featured,
            chrome: chrome,
            onTap: shouldHandleTap ? {
                if appState.currentState == .expanded {
                    appState.fullyExpand()
                    appState.cancelFullExpandedCollapse()
                } else if notification.tapAction != nil {
                    manager.activateNotification(notification)
                }
            } : nil
        ) {
            manager.clearNotification(notification.id)
        } content: {
            HStack(alignment: .top, spacing: featured ? 10 : 8) {
                notificationLeadingView(notification, size: featured ? 30 : 18, showsRing: chrome == .card)

                VStack(alignment: .leading, spacing: featured ? 2 : 1) {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: featured ? 2 : 1) {
                            if featured {
                                Text(notification.appName)
                                    .font(.system(size: 10))
                                    .foregroundColor(.white.opacity(0.5))
                                    .lineLimit(1)
                            }

                            Text(headline(for: notification))
                                .font(.system(size: featured ? 13 : 11, weight: .semibold))
                                .foregroundColor(.white.opacity(featured ? 1 : 0.9))
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)

                        Text(timeAgo(notification.timestamp))
                            .font(.system(size: featured ? 10 : 9))
                            .foregroundColor(.white.opacity(featured ? 0.4 : 0.3))
                            .lineLimit(1)
                            .fixedSize()
                    }

                    if let message = message(for: notification) {
                        Text(message)
                            .font(.system(size: featured ? 10 : 10))
                            .foregroundColor(.white.opacity(0.72))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
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
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        if lowered == "undefined" || lowered == "null" || lowered == "(null)" {
            return nil
        }
        return trimmed
    }

    @ViewBuilder
    private func notificationLeadingView(_ notification: IslandNotification, size: CGFloat, showsRing: Bool) -> some View {
        if let avatar = image(from: notification.avatarURL) {
            Image(nsImage: avatar)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay {
                    if showsRing {
                        Circle()
                            .stroke(.white.opacity(0.14), lineWidth: 0.8)
                    }
                }
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

private enum NotificationRowChrome {
    case plain
    case card
}

private struct SwipeToDismissNotificationRow<Content: View>: View {
    let featured: Bool
    let chrome: NotificationRowChrome
    let onTap: (() -> Void)?
    let onDismiss: () -> Void
    let content: Content

    @State private var dragOffset: CGFloat = 0
    @State private var isRemoving = false

    private let dismissThreshold: CGFloat = 88
    private let maxDragDistance: CGFloat = 128

    init(
        featured: Bool,
        chrome: NotificationRowChrome,
        onTap: (() -> Void)? = nil,
        onDismiss: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.featured = featured
        self.chrome = chrome
        self.onTap = onTap
        self.onDismiss = onDismiss
        self.content = content()
    }

    var body: some View {
        ZStack {
            swipeBackground

            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .background(backgroundView)
                .offset(x: dragOffset)
        }
        .opacity(isRemoving ? 0 : 1)
        .contentShape(Rectangle())
        .simultaneousGesture(rowDragGesture)
        .onTapGesture {
            onTap?()
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.84), value: dragOffset)
        .animation(.easeOut(duration: 0.18), value: isRemoving)
    }

    @ViewBuilder
    private var backgroundView: some View {
        switch chrome {
        case .plain:
            Color.clear
        case .card:
            RoundedRectangle(cornerRadius: featured ? 16 : 12, style: .continuous)
                .fill(.white.opacity(featured ? 0.045 : 0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: featured ? 16 : 12, style: .continuous)
                        .stroke(.white.opacity(featured ? 0.09 : 0.06), lineWidth: 1)
                )
        }
    }

    private var horizontalPadding: CGFloat {
        switch chrome {
        case .plain:
            return 0
        case .card:
            return featured ? 12 : 10
        }
    }

    private var verticalPadding: CGFloat {
        switch chrome {
        case .plain:
            return 0
        case .card:
            return featured ? 10 : 9
        }
    }

    private var swipeBackground: some View {
        RoundedRectangle(cornerRadius: chrome == .card ? (featured ? 16 : 12) : 10, style: .continuous)
            .fill(.white.opacity(chrome == .card ? 0.04 : 0.025))
            .overlay {
                HStack {
                    swipeIndicator(visible: dragOffset > 0)
                    Spacer(minLength: 0)
                    swipeIndicator(visible: dragOffset < 0)
                }
                .padding(.horizontal, chrome == .card ? 12 : 6)
            }
            .opacity(min(1, Double(abs(dragOffset) / dismissThreshold)))
    }

    private func swipeIndicator(visible: Bool) -> some View {
        Image(systemName: "xmark")
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.white.opacity(visible ? 0.88 : 0))
            .frame(width: 22, height: 22)
            .background(
                Circle()
                    .fill(.white.opacity(visible ? 0.12 : 0))
            )
    }

    private var rowDragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                dragOffset = max(-maxDragDistance, min(maxDragDistance, value.translation.width))
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
                        dragOffset = 0
                    }
                    return
                }

                if abs(value.translation.width) >= dismissThreshold {
                    let finalOffset = value.translation.width >= 0 ? maxDragDistance * 1.15 : -maxDragDistance * 1.15
                    withAnimation(.easeIn(duration: 0.16)) {
                        dragOffset = finalOffset
                        isRemoving = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                        onDismiss()
                    }
                } else {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
                        dragOffset = 0
                    }
                }
            }
    }
}
