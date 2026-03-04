import Foundation
import UserNotifications
import Combine

struct IslandNotification: Identifiable {
    let id = UUID()
    let appName: String
    let appIcon: String
    let title: String
    let body: String
    let timestamp: Date
}

@MainActor
final class NotificationManager: ObservableObject {
    static let shared = NotificationManager()

    @Published var latestNotification: IslandNotification?
    @Published var recentNotifications: [IslandNotification] = []
    @Published var hasPermission: Bool = false

    private let maxNotifications = 10

    private init() {
        checkPermission()
        startMonitoring()
    }

    // MARK: - Permission

    func checkPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.hasPermission = settings.authorizationStatus == .authorized
            }
        }
    }

    func requestPermission() {
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .badge])
                await MainActor.run {
                    hasPermission = granted
                }
            } catch {
                print("Notification permission error: \(error)")
            }
        }
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        // Monitor distributed notifications for app notifications
        // Note: macOS doesn't provide a direct API to read other apps' notifications
        // This uses distributed notification center for apps that broadcast
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleDistributedNotification(_:)),
            name: nil, // Listen to all
            object: nil
        )
    }

    @objc private func handleDistributedNotification(_ notification: Notification) {
        // Filter for notification-like events
        let name = notification.name.rawValue
        guard name.contains("notification") || name.contains("Notification") else { return }

        let notif = IslandNotification(
            appName: notification.object as? String ?? "System",
            appIcon: "app.badge",
            title: name,
            body: "",
            timestamp: Date()
        )

        addNotification(notif)
    }

    // MARK: - Public API

    func addNotification(_ notification: IslandNotification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.latestNotification = notification
            self.recentNotifications.insert(notification, at: 0)
            if self.recentNotifications.count > self.maxNotifications {
                self.recentNotifications.removeLast()
            }
            AppState.shared.showHUD(module: .notifications)
        }
    }

    func clearNotification(_ id: UUID) {
        recentNotifications.removeAll { $0.id == id }
        if latestNotification?.id == id {
            latestNotification = recentNotifications.first
        }
    }

    func clearAll() {
        recentNotifications.removeAll()
        latestNotification = nil
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }
}
