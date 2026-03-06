import Foundation
import UserNotifications
import Combine
import AppKit
import ApplicationServices

struct IslandNotification: Identifiable {
    let id = UUID()
    let sourceID: String
    let appName: String
    let bundleIdentifier: String?
    let appIcon: String
    let appIconURL: String?
    let title: String
    let body: String
    let senderName: String?
    let previewText: String?
    let avatarURL: String?
    let timestamp: Date
}

@MainActor
final class NotificationManager: ObservableObject {
    private struct WhatsAppLogEvent {
        let eventID: String
        let timestamp: Date
        let avatarURL: String?
    }

    static let shared = NotificationManager()

    @Published var latestNotification: IslandNotification?
    @Published var recentNotifications: [IslandNotification] = []
    @Published var hasPermission: Bool = false

    private let maxNotifications = 10
    private let logMonitorQueue = DispatchQueue(label: "com.workview.dynamic.whatsapp-log-monitor", qos: .utility)
    private let deliveredMonitorQueue = DispatchQueue(label: "com.workview.dynamic.notifications-delivered-monitor", qos: .utility)
    private var whatsappLogMonitorTimer: DispatchSourceTimer?
    private var deliveredNotificationMonitorTimer: DispatchSourceTimer?
    private var seenWhatsAppEventIDs: [String] = []
    private var seenDeliveredNotificationIDs: [String] = []
    private let maxSeenWhatsAppEventIDs = 80
    private let maxSeenDeliveredNotificationIDs = 200
    private var hasRequestedAccessibilityPrompt = false

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

        startWhatsAppLogMonitor()
        startDeliveredNotificationMonitor()
        ensureAccessibilityPromptIfNeeded()
    }

    private func ensureAccessibilityPromptIfNeeded() {
        guard !AXIsProcessTrusted(), !hasRequestedAccessibilityPrompt else { return }
        hasRequestedAccessibilityPrompt = true
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @objc private func handleDistributedNotification(_ notification: Notification) {
        // Filter for notification-like events
        let name = notification.name.rawValue
        guard name.contains("notification") || name.contains("Notification") else { return }

        let extracted = extractNotificationFields(from: notification)

        let notif = IslandNotification(
            sourceID: "distributed:\(UUID().uuidString)",
            appName: extracted.appName,
            bundleIdentifier: extracted.bundleIdentifier,
            appIcon: iconName(for: extracted.appName),
            appIconURL: nil,
            title: extracted.title.isEmpty ? name : extracted.title,
            body: extracted.body,
            senderName: extracted.senderName,
            previewText: extracted.body.isEmpty ? nil : extracted.body,
            avatarURL: extracted.avatarURL,
            timestamp: Date()
        )

        addNotification(notif)
    }

    private func extractNotificationFields(
        from notification: Notification
    ) -> (appName: String, bundleIdentifier: String?, title: String, body: String, senderName: String?, avatarURL: String?) {
        let userInfo = notification.userInfo ?? [:]

        let bundleIdentifierCandidates: [String?] = [
            userInfo["bundleIdentifier"] as? String,
            userInfo["bundleID"] as? String,
            userInfo["applicationBundleIdentifier"] as? String,
            userInfo["com.apple.UNNotificationSourceBundleIdentifier"] as? String
        ]

        let appNameCandidates: [String?] = [
            notification.object as? String,
            userInfo["appName"] as? String,
            userInfo["applicationName"] as? String,
            userInfo["NSApplicationName"] as? String,
            userInfo["sender"] as? String,
            userInfo["bundleIdentifier"] as? String,
            userInfo["bundleID"] as? String,
            userInfo["com.apple.UNNotificationSourceBundleIdentifier"] as? String
        ]

        let titleCandidates: [String?] = [
            userInfo["title"] as? String,
            userInfo["summary"] as? String,
            userInfo["subject"] as? String,
            userInfo["message"] as? String,
            notification.name.rawValue
        ]

        let bodyCandidates: [String?] = [
            userInfo["body"] as? String,
            userInfo["subtitle"] as? String,
            userInfo["informativeText"] as? String,
            userInfo["messageBody"] as? String
        ]

        let senderNameCandidates: [String?] = [
            userInfo["sender"] as? String,
            userInfo["senderName"] as? String,
            userInfo["from"] as? String
        ]

        let avatarURLCandidates: [String?] = [
            userInfo["avatarURL"] as? String,
            userInfo["imageURL"] as? String,
            userInfo["senderImageURL"] as? String,
            userInfo["iconURL"] as? String
        ]

        let bundleIdentifier = firstNonEmptyString(in: bundleIdentifierCandidates)
        let rawAppName = firstNonEmptyString(in: appNameCandidates) ?? "System"
        let appName = prettifiedAppName(from: rawAppName)
        let title = firstNonAppLabel(in: titleCandidates) ?? firstNonEmptyString(in: titleCandidates) ?? notification.name.rawValue
        let body = firstNonEmptyString(in: bodyCandidates) ?? ""
        let senderName = firstNonAppLabel(
            in: senderNameCandidates + [userInfo["subtitle"] as? String, title]
        )
        let avatarURL = firstNonEmptyString(in: avatarURLCandidates)

        return (
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            title: title,
            body: body,
            senderName: senderName,
            avatarURL: avatarURL
        )
    }

    private func firstNonEmptyString(in values: [String?]) -> String? {
        for value in values {
            guard let value else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private func firstNonAppLabel(in values: [String?]) -> String? {
        for value in values {
            guard let trimmed = sanitizedString(value) else { continue }
            if !looksLikeAppLabel(trimmed) {
                return trimmed
            }
        }
        return nil
    }

    private func sanitizedString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func looksLikeAppLabel(_ value: String) -> Bool {
        let lowered = value.lowercased()
        if lowered == "whatsapp" || lowered == "new whatsapp message" || lowered == "new message" || lowered == "message" {
            return true
        }
        return lowered.contains("whatsapp")
    }

    private func prettifiedAppName(from rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "System" }

        if trimmed.localizedCaseInsensitiveContains("whatsapp") {
            return "WhatsApp"
        }

        if trimmed.contains("."), let last = trimmed.split(separator: ".").last, !last.isEmpty {
            return String(last)
        }

        return trimmed
    }

    private func iconName(for appName: String) -> String {
        if appName.localizedCaseInsensitiveContains("whatsapp") {
            return "message.fill"
        }
        return "app.badge"
    }

    private func startWhatsAppLogMonitor() {
        let timer = DispatchSource.makeTimerSource(queue: logMonitorQueue)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }

            let events = Self.fetchWhatsAppEventsFromUnifiedLog()
            guard !events.isEmpty else { return }

            Task { @MainActor [weak self] in
                self?.ingestWhatsAppLogEvents(events)
            }
        }

        whatsappLogMonitorTimer = timer
        timer.resume()
    }

    private static func fetchWhatsAppEventsFromUnifiedLog() -> [WhatsAppLogEvent] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "show",
            "--style", "compact",
            "--last", "8s",
            "--predicate",
            "process == \"NotificationCenter\" AND eventMessage CONTAINS[c] \"whatsapp\""
        ]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return []
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return []
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8), !output.isEmpty else {
            return []
        }

        let timestampFormatter = DateFormatter()
        timestampFormatter.locale = Locale(identifier: "en_US_POSIX")
        timestampFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        let addOrUpdatePattern = #"addOrUpdate listItem:\s+(net\.whatsapp\.WhatsApp:[^\s]+)"#
        let addOrUpdateRegex = try? NSRegularExpression(pattern: addOrUpdatePattern)
        let imagePattern = #"proxyIdentifier=([A-F0-9-]+\.png)"#
        let imageRegex = try? NSRegularExpression(pattern: imagePattern)
        var events: [WhatsAppLogEvent] = []
        var recentImageEvents: [(timestamp: Date, avatarURL: String)] = []

        for line in output.split(whereSeparator: \.isNewline) {
            let text = String(line)

            let timestampText = String(text.prefix(23))
            let timestamp = timestampFormatter.date(from: timestampText) ?? Date()

            if let imageRegex,
               let imageMatch = imageRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let imageRange = Range(imageMatch.range(at: 1), in: text) {
                let imageName = String(text[imageRange])
                let imagePath = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Intents/Images/\(imageName)")
                if FileManager.default.fileExists(atPath: imagePath) {
                    recentImageEvents.append((timestamp: timestamp, avatarURL: URL(fileURLWithPath: imagePath).absoluteString))
                    if recentImageEvents.count > 20 {
                        recentImageEvents.removeFirst(recentImageEvents.count - 20)
                    }
                }
            }

            guard text.contains("addOrUpdate listItem:") else { continue }

            var eventID = text
            if let addOrUpdateRegex,
               let match = addOrUpdateRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let range = Range(match.range(at: 1), in: text) {
                eventID = String(text[range])
            }

            let avatarURL = recentImageEvents
                .filter { abs($0.timestamp.timeIntervalSince(timestamp)) <= 30 }
                .sorted(by: { abs($0.timestamp.timeIntervalSince(timestamp)) < abs($1.timestamp.timeIntervalSince(timestamp)) })
                .first?
                .avatarURL

            events.append(WhatsAppLogEvent(eventID: eventID, timestamp: timestamp, avatarURL: avatarURL))
        }

        return events
    }

    private func ingestWhatsAppLogEvents(_ events: [WhatsAppLogEvent]) {
        for event in events.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard !seenWhatsAppEventIDs.contains(event.eventID) else { continue }
            seenWhatsAppEventIDs.append(event.eventID)
            if seenWhatsAppEventIDs.count > maxSeenWhatsAppEventIDs {
                seenWhatsAppEventIDs.removeFirst(seenWhatsAppEventIDs.count - maxSeenWhatsAppEventIDs)
            }

            let bannerSnapshot = captureWhatsAppBannerSnapshot()
            let notif = buildWhatsAppNotification(event: event, snapshot: bannerSnapshot)
            addNotification(notif)

            if bannerSnapshot.senderName == nil || bannerSnapshot.previewText == nil {
                scheduleWhatsAppEnrichment(for: event)
            }
        }
    }

    private func buildWhatsAppNotification(
        event: WhatsAppLogEvent,
        snapshot: (senderName: String?, previewText: String?)
    ) -> IslandNotification {
        let senderName = snapshot.senderName
        let previewText = snapshot.previewText
        let title = senderName ?? "New WhatsApp message"

        return IslandNotification(
            sourceID: "whatsapp-log:\(event.eventID)",
            appName: "WhatsApp",
            bundleIdentifier: "net.whatsapp.WhatsApp",
            appIcon: "message.fill",
            appIconURL: nil,
            title: title,
            body: previewText ?? "",
            senderName: senderName,
            previewText: previewText,
            avatarURL: event.avatarURL,
            timestamp: event.timestamp
        )
    }

    private func scheduleWhatsAppEnrichment(for event: WhatsAppLogEvent) {
        let delaysMS: [UInt64] = [250, 600, 1200, 2200]
        Task { @MainActor [weak self] in
            guard let self else { return }
            for delayMS in delaysMS {
                try? await Task.sleep(nanoseconds: delayMS * 1_000_000)
                let completed = self.attemptWhatsAppEnrichment(for: event)
                if completed {
                    return
                }
            }
        }
    }

    @MainActor
    private func attemptWhatsAppEnrichment(for event: WhatsAppLogEvent) -> Bool {
        let snapshot = captureWhatsAppBannerSnapshot()
        guard snapshot.senderName != nil || snapshot.previewText != nil else {
            return false
        }

        let notif = buildWhatsAppNotification(event: event, snapshot: snapshot)
        addNotification(notif)
        return snapshot.senderName != nil && snapshot.previewText != nil
    }

    private func captureWhatsAppBannerSnapshot() -> (senderName: String?, previewText: String?) {
        guard AXIsProcessTrusted() else {
            return (nil, nil)
        }

        let candidateApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui")
            + NSWorkspace.shared.runningApplications.filter { ($0.localizedName ?? "").localizedCaseInsensitiveContains("NotificationCenter") }

        guard let app = candidateApps.first(where: { $0.processIdentifier > 0 }) else {
            return (nil, nil)
        }

        let root = AXUIElementCreateApplication(app.processIdentifier)
        let texts = collectAXText(from: root, maxDepth: 8, maxNodes: 600)
        guard !texts.isEmpty else {
            return (nil, nil)
        }

        return parseWhatsAppTextSnapshot(from: texts)
    }

    private func collectAXText(from root: AXUIElement, maxDepth: Int, maxNodes: Int) -> [String] {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visitedCount = 0
        var results: [String] = []

        while !queue.isEmpty && visitedCount < maxNodes {
            let (element, depth) = queue.removeFirst()
            visitedCount += 1

            appendStringAttribute(kAXTitleAttribute as CFString, from: element, into: &results)
            appendStringAttribute(kAXValueAttribute as CFString, from: element, into: &results)
            appendStringAttribute(kAXDescriptionAttribute as CFString, from: element, into: &results)

            guard depth < maxDepth else { continue }
            let childAttributes: [CFString] = [
                kAXChildrenAttribute as CFString,
                kAXVisibleChildrenAttribute as CFString,
                "AXContents" as CFString,
                "AXRows" as CFString
            ]

            for attribute in childAttributes {
                for child in childElements(of: element, attribute: attribute) {
                    queue.append((child, depth + 1))
                }
            }
        }

        return results
    }

    private func appendStringAttribute(_ attribute: CFString, from element: AXUIElement, into output: inout [String]) {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else {
            return
        }

        if let string = value as? String {
            let normalized = string
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty {
                output.append(normalized)
            }
            return
        }

        if let attributed = value as? NSAttributedString {
            let normalized = attributed.string
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty {
                output.append(normalized)
            }
        }
    }

    private func childElements(of element: AXUIElement, attribute: CFString) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else {
            return []
        }

        if let elements = value as? [AXUIElement] {
            return elements
        }

        return []
    }

    private func parseWhatsAppTextSnapshot(from rawTexts: [String]) -> (senderName: String?, previewText: String?) {
        var cleaned: [String] = []
        for text in rawTexts {
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            if cleaned.last != normalized {
                cleaned.append(normalized)
            }
        }

        guard !cleaned.isEmpty else {
            return (nil, nil)
        }

        let filtered = cleaned.filter { text in
            let lowered = text.lowercased()
            if lowered == "open" || lowered == "close" || lowered == "clear all" {
                return false
            }
            if lowered == "just now" || lowered.hasSuffix(" ago") || lowered.hasSuffix("m ago") || lowered.hasSuffix("h ago") {
                return false
            }
            return true
        }

        guard !filtered.isEmpty else {
            return (nil, nil)
        }

        var startIndex = 0
        if let whatsappIndex = filtered.lastIndex(where: { $0.lowercased() == "whatsapp" || $0.lowercased().contains("whatsapp") }) {
            startIndex = min(filtered.count - 1, whatsappIndex + 1)
        }

        let tailCandidates = Array(filtered[startIndex...])
        let candidates = Array(tailCandidates.prefix(6))

        let sender = candidates.first { candidate in
            !looksLikeAppLabel(candidate) && !isTimeLikeLabel(candidate)
        }

        var preview: String?
        if let sender, let senderIndex = candidates.firstIndex(of: sender) {
            if senderIndex + 1 < candidates.count {
                let possiblePreview = candidates[senderIndex + 1]
                if !looksLikeAppLabel(possiblePreview)
                    && !isTimeLikeLabel(possiblePreview)
                    && possiblePreview.localizedCaseInsensitiveCompare(sender) != .orderedSame {
                    preview = possiblePreview
                }
            }
        }

        if sender == nil, let inline = candidates.first(where: { $0.contains(":") && !looksLikeAppLabel($0) }) {
            let components = inline.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
            if components.count == 2 {
                let inlineSender = String(components[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                let inlinePreview = String(components[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !inlineSender.isEmpty && !looksLikeAppLabel(inlineSender) {
                    return (inlineSender, inlinePreview.isEmpty ? nil : inlinePreview)
                }
            }
        }

        if preview == nil {
            preview = candidates.first { candidate in
                !looksLikeAppLabel(candidate)
                    && !isTimeLikeLabel(candidate)
                    && candidate.localizedCaseInsensitiveCompare(sender ?? "") != .orderedSame
            }
        }

        return (
            senderName: sender,
            previewText: preview
        )
    }

    private func isTimeLikeLabel(_ value: String) -> Bool {
        let lowered = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lowered == "just now" {
            return true
        }
        if lowered.hasSuffix(" ago") || lowered.hasSuffix("m ago") || lowered.hasSuffix("h ago") {
            return true
        }
        return false
    }

    private func startDeliveredNotificationMonitor() {
        let timer = DispatchSource.makeTimerSource(queue: deliveredMonitorQueue)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(2))
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.pollDeliveredNotifications()
            }
        }

        deliveredNotificationMonitorTimer = timer
        timer.resume()
    }

    @MainActor
    private func pollDeliveredNotifications() {
        UNUserNotificationCenter.current().getDeliveredNotifications { [weak self] delivered in
            guard let self else { return }
            let parsed = self.parseWhatsAppDeliveredNotifications(delivered)
            guard !parsed.isEmpty else { return }

            Task { @MainActor [weak self] in
                self?.ingestDeliveredNotifications(parsed)
            }
        }
    }

    private func parseWhatsAppDeliveredNotifications(_ delivered: [UNNotification]) -> [IslandNotification] {
        var parsed: [IslandNotification] = []

        for notification in delivered {
            let request = notification.request
            let content = request.content
            let userInfo = content.userInfo

            let identifier = request.identifier
            let bundleIdentifier = firstNonEmptyString(in: [
                userInfo["bundleIdentifier"] as? String,
                userInfo["bundleID"] as? String,
                userInfo["applicationBundleIdentifier"] as? String,
                userInfo["com.apple.UNNotificationSourceBundleIdentifier"] as? String
            ])

            let looksLikeWhatsApp =
                identifier.localizedCaseInsensitiveContains("whatsapp")
                || (bundleIdentifier?.localizedCaseInsensitiveContains("whatsapp") ?? false)
                || (userInfo.description.localizedCaseInsensitiveContains("whatsapp"))
                || content.title.localizedCaseInsensitiveContains("whatsapp")
                || content.subtitle.localizedCaseInsensitiveContains("whatsapp")

            guard looksLikeWhatsApp else { continue }

            let titleText = sanitizedString(content.title)
            let subtitleText = sanitizedString(content.subtitle)
            let bodyText = sanitizedString(content.body)

            let senderName = firstNonAppLabel(in: [
                userInfo["senderName"] as? String,
                userInfo["sender"] as? String,
                userInfo["from"] as? String,
                userInfo["contactName"] as? String,
                userInfo["author"] as? String,
                userInfo["chatName"] as? String,
                userInfo["threadName"] as? String,
                subtitleText,
                sanitizedString(content.summaryArgument),
                sanitizedString(content.threadIdentifier),
                titleText
            ])

            var previewText = firstNonEmptyString(in: [
                userInfo["message"] as? String,
                userInfo["messageBody"] as? String,
                userInfo["body"] as? String,
                userInfo["text"] as? String,
                userInfo["previewText"] as? String,
                bodyText,
                subtitleText
            ])
            if let unwrappedPreviewText = previewText,
               let senderName,
               unwrappedPreviewText.localizedCaseInsensitiveCompare(senderName) == .orderedSame {
                previewText = nil
            }
            if let unwrappedPreviewText = previewText, looksLikeAppLabel(unwrappedPreviewText) {
                previewText = nil
            }

            let title = senderName
                ?? firstNonAppLabel(in: [titleText, subtitleText])
                ?? "New WhatsApp message"

            let avatarURL = firstNonEmptyString(in: [
                content.attachments.first?.url.absoluteString,
                userInfo["avatarURL"] as? String,
                userInfo["senderImageURL"] as? String,
                userInfo["imageURL"] as? String,
                userInfo["iconURL"] as? String
            ])
            let sourceID = "delivered:\(identifier):\(title):\(previewText ?? ""):\(Int(notification.date.timeIntervalSince1970))"

            parsed.append(
                IslandNotification(
                    sourceID: sourceID,
                    appName: "WhatsApp",
                    bundleIdentifier: bundleIdentifier ?? "net.whatsapp.WhatsApp",
                    appIcon: "message.fill",
                    appIconURL: nil,
                    title: title,
                    body: previewText ?? "",
                    senderName: senderName,
                    previewText: previewText,
                    avatarURL: avatarURL,
                    timestamp: notification.date
                )
            )
        }

        return parsed
    }

    @MainActor
    private func ingestDeliveredNotifications(_ notifications: [IslandNotification]) {
        for notification in notifications {
            guard !seenDeliveredNotificationIDs.contains(notification.sourceID) else { continue }
            seenDeliveredNotificationIDs.append(notification.sourceID)
            if seenDeliveredNotificationIDs.count > maxSeenDeliveredNotificationIDs {
                seenDeliveredNotificationIDs.removeFirst(
                    seenDeliveredNotificationIDs.count - maxSeenDeliveredNotificationIDs
                )
            }
            addNotification(notification)
        }
    }

    // MARK: - Public API

    func addNotification(_ notification: IslandNotification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.latestNotification = notification
            self.recentNotifications.removeAll { $0.sourceID == notification.sourceID }
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
        whatsappLogMonitorTimer?.cancel()
        whatsappLogMonitorTimer = nil
        deliveredNotificationMonitorTimer?.cancel()
        deliveredNotificationMonitorTimer = nil
        DistributedNotificationCenter.default().removeObserver(self)
    }
}
