import Foundation
import UserNotifications
import Combine
import AppKit
import ApplicationServices

struct IslandNotification: Identifiable {
    var id: String { sourceID }
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

    private struct DismissedNotificationRecord {
        let sourceID: String
        let appName: String
        let senderName: String?
        let previewText: String?
        let timestamp: Date
        let dismissedAt: Date
        let qualityScore: Int
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
    private let maxDismissedNotifications = 80
    private let dismissedNotificationRetention: TimeInterval = 300
    private let lowInformationSuppressionWindow: TimeInterval = 10
    private var dismissedNotifications: [DismissedNotificationRecord] = []
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
        timer.schedule(deadline: .now() + .milliseconds(300), repeating: .seconds(1))
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
            "--last", "3s",
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
            if snapshotHasSignal(bannerSnapshot) {
                let notif = buildWhatsAppNotification(event: event, snapshot: bannerSnapshot)
                addNotification(notif)
                if !snapshotIsComplete(bannerSnapshot) {
                    scheduleWhatsAppEnrichment(for: event, emitFallbackIfNeeded: false)
                }
            } else {
                // Delay the generic fallback slightly so we can capture sender/preview
                // from the live banner before it disappears.
                scheduleWhatsAppEnrichment(for: event, emitFallbackIfNeeded: true)
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

    private func scheduleWhatsAppEnrichment(for event: WhatsAppLogEvent, emitFallbackIfNeeded: Bool) {
        let delaysMS: [UInt64] = [80, 180, 320, 520, 850, 1300, 2000, 2900, 4000]
        Task { @MainActor [weak self] in
            guard let self else { return }
            var bestSnapshot: (senderName: String?, previewText: String?) = (nil, nil)
            for delayMS in delaysMS {
                try? await Task.sleep(nanoseconds: delayMS * 1_000_000)
                let snapshot = self.captureWhatsAppBannerSnapshot()
                if self.snapshotScore(snapshot) > self.snapshotScore(bestSnapshot) {
                    bestSnapshot = snapshot
                }

                guard self.snapshotHasSignal(snapshot) else { continue }

                let notif = self.buildWhatsAppNotification(event: event, snapshot: snapshot)
                self.addNotification(notif)

                if self.snapshotIsComplete(snapshot) {
                    return
                }
            }

            if self.snapshotHasSignal(bestSnapshot) {
                let notif = self.buildWhatsAppNotification(event: event, snapshot: bestSnapshot)
                self.addNotification(notif)
                return
            }

            if emitFallbackIfNeeded {
                let notif = self.buildWhatsAppNotification(
                    event: event,
                    snapshot: (senderName: nil, previewText: nil)
                )
                self.addNotification(notif)
            }
        }
    }

    private func snapshotHasSignal(_ snapshot: (senderName: String?, previewText: String?)) -> Bool {
        snapshot.senderName != nil || snapshot.previewText != nil
    }

    private func snapshotIsComplete(_ snapshot: (senderName: String?, previewText: String?)) -> Bool {
        snapshot.senderName != nil && snapshot.previewText != nil
    }

    private func snapshotScore(_ snapshot: (senderName: String?, previewText: String?)) -> Int {
        var score = 0
        if let senderName = snapshot.senderName, !looksLikeAppLabel(senderName) {
            score += 2
        }
        if let previewText = snapshot.previewText, !looksLikeAppLabel(previewText) {
            score += 3
            if previewText.count >= 8 {
                score += 1
            }
        }
        return score
    }

    private func captureWhatsAppBannerSnapshot() -> (senderName: String?, previewText: String?) {
        guard AXIsProcessTrusted() else {
            return (nil, nil)
        }

        let allCandidates =
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui")
            + NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter")
            + NSWorkspace.shared.runningApplications.filter { app in
                let name = (app.localizedName ?? "").lowercased()
                let bundleIdentifier = (app.bundleIdentifier ?? "").lowercased()
                return name.contains("notificationcenter")
                    || name.contains("notification center")
                    || name.contains("usernotificationcenter")
                    || name.contains("controlcenter")
                    || bundleIdentifier.contains("notificationcenter")
                    || bundleIdentifier.contains("controlcenter")
            }

        var seenProcessIDs = Set<pid_t>()
        let candidateApps = allCandidates
            .filter { app in
                guard app.processIdentifier > 0 else { return false }
                return seenProcessIDs.insert(app.processIdentifier).inserted
            }
            .sorted(by: { lhs, rhs in
                notificationUIProcessPriority(lhs) < notificationUIProcessPriority(rhs)
            })

        guard !candidateApps.isEmpty else {
            return (nil, nil)
        }

        var bestSnapshot: (senderName: String?, previewText: String?) = (nil, nil)
        var bestScore = snapshotScore(bestSnapshot)

        for app in candidateApps {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            let texts = collectAXText(from: root, maxDepth: 10, maxNodes: 1200)
            guard !texts.isEmpty else { continue }

            let snapshot = parseWhatsAppTextSnapshot(from: texts)
            let score = snapshotScore(snapshot)
            if score > bestScore {
                bestSnapshot = snapshot
                bestScore = score
            }

            if snapshotIsComplete(snapshot) {
                return snapshot
            }
        }

        return bestSnapshot
    }

    private func notificationUIProcessPriority(_ app: NSRunningApplication) -> Int {
        let bundleIdentifier = (app.bundleIdentifier ?? "").lowercased()
        let name = (app.localizedName ?? "").lowercased()

        if bundleIdentifier.contains("usernotificationcenter") || name.contains("usernotificationcenter") {
            return 0
        }
        if bundleIdentifier == "com.apple.notificationcenterui" || name == "notificationcenter" || name.contains("notification center") {
            return 1
        }
        if bundleIdentifier == "com.apple.controlcenter" || name.contains("controlcenter") {
            return 2
        }
        return 3
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
            appendStringAttribute("AXLabel" as CFString, from: element, into: &results)
            appendStringAttribute("AXHelp" as CFString, from: element, into: &results)

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
            guard let normalized = sanitizeSnapshotToken(text) else { continue }
            if cleaned.last?.localizedCaseInsensitiveCompare(normalized) != .orderedSame {
                cleaned.append(normalized)
            }
        }

        guard !cleaned.isEmpty else {
            return (nil, nil)
        }

        let filtered = cleaned.filter { text in
            !isActionLabel(text) && !isTimeLikeLabel(text)
        }

        guard !filtered.isEmpty else {
            return (nil, nil)
        }

        for token in filtered {
            if let inline = parseInlineSenderPreview(from: token) {
                return inline
            }
        }

        struct SnapshotCandidate {
            let senderName: String?
            let previewText: String?
            let score: Int
        }

        func buildCandidate(senderName: String?, previewText: String?) -> SnapshotCandidate? {
            let normalizedSender = cleanedSenderLabel(senderName)
            let normalizedPreview = cleanedPreviewLabel(previewText, senderName: normalizedSender)

            guard normalizedSender != nil || normalizedPreview != nil else {
                return nil
            }

            var score = 0
            if let sender = normalizedSender {
                score += 4
                if sender.count <= 28 {
                    score += 1
                }
            }
            if let preview = normalizedPreview {
                score += 5
                if preview.count >= 10 {
                    score += 1
                }
                if preview.split(whereSeparator: \.isWhitespace).count >= 2 {
                    score += 1
                }
            }
            if normalizedSender != nil && normalizedPreview != nil {
                score += 3
            }

            return SnapshotCandidate(
                senderName: normalizedSender,
                previewText: normalizedPreview,
                score: score
            )
        }

        var bestCandidate: SnapshotCandidate?
        func consider(senderName: String?, previewText: String?) {
            guard let candidate = buildCandidate(senderName: senderName, previewText: previewText) else {
                return
            }
            if bestCandidate == nil || candidate.score > bestCandidate?.score ?? 0 {
                bestCandidate = candidate
            }
        }

        let lookAhead = 6
        for (index, token) in filtered.enumerated() where looksLikeAppLabel(token) {
            guard index + 1 < filtered.count else { continue }
            let endIndex = min(filtered.count, index + 1 + lookAhead)
            let window = Array(filtered[(index + 1)..<endIndex])
            guard !window.isEmpty else { continue }

            let sender = window.first(where: { isLikelySenderLabel($0) })
            var preview: String?

            if let sender,
               let senderIndex = window.firstIndex(of: sender),
               senderIndex + 1 < window.count {
                preview = window[(senderIndex + 1)...].first {
                    isLikelyPreviewLabel($0, excluding: sender)
                }
            }

            if preview == nil {
                preview = window.first { isLikelyPreviewLabel($0, excluding: sender) }
            }

            consider(senderName: sender, previewText: preview)
        }

        for index in filtered.indices {
            let first = filtered[index]
            let second = index + 1 < filtered.count ? filtered[index + 1] : nil
            let third = index + 2 < filtered.count ? filtered[index + 2] : nil

            if isLikelySenderLabel(first) {
                consider(senderName: first, previewText: second)
                consider(senderName: first, previewText: third)
            }

            if let second, isLikelySenderLabel(second) {
                consider(senderName: second, previewText: third)
            }

            if isLikelyPreviewLabel(first, excluding: nil) {
                consider(senderName: nil, previewText: first)
            }
        }

        if let bestCandidate {
            return (
                senderName: bestCandidate.senderName,
                previewText: bestCandidate.previewText
            )
        }

        if let preview = filtered.first(where: { isLikelyPreviewLabel($0, excluding: nil) }) {
            return (
                senderName: nil,
                previewText: cleanedPreviewLabel(preview, senderName: nil)
            )
        }

        return (nil, nil)
    }

    private func sanitizeSnapshotToken(_ value: String) -> String? {
        guard let raw = sanitizedString(value) else { return nil }
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed
    }

    private func isActionLabel(_ value: String) -> Bool {
        let lowered = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch lowered {
        case "open", "close", "clear all", "notifications", "notification center", "options", "reply", "mark as read":
            return true
        default:
            return false
        }
    }

    private func parseInlineSenderPreview(from value: String) -> (senderName: String?, previewText: String?)? {
        guard let text = sanitizedString(value), text.contains(":") else { return nil }

        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }

        let sender = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)

        guard isLikelySenderLabel(sender) else { return nil }

        let normalizedSender = cleanedSenderLabel(sender)
        let normalizedPreview = cleanedPreviewLabel(preview, senderName: normalizedSender)

        guard normalizedSender != nil || normalizedPreview != nil else {
            return nil
        }

        return (
            senderName: normalizedSender,
            previewText: normalizedPreview
        )
    }

    private func isLikelySenderLabel(_ value: String) -> Bool {
        guard let token = cleanedSenderLabel(value) else { return false }
        guard token.count >= 2, token.count <= 64 else { return false }
        guard !token.contains(":"), !token.contains("http://"), !token.contains("https://") else { return false }

        let wordCount = token.split(whereSeparator: \.isWhitespace).count
        guard wordCount >= 1, wordCount <= 8 else { return false }

        if token.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?")) != nil && token.count > 24 {
            return false
        }

        return true
    }

    private func isLikelyPreviewLabel(_ value: String, excluding sender: String?) -> Bool {
        guard let preview = cleanedPreviewLabel(value, senderName: sender) else {
            return false
        }
        guard preview.count >= 2 else { return false }
        let lowered = preview.lowercased()
        if lowered == "preview unavailable" {
            return false
        }
        return true
    }

    private func cleanedSenderLabel(_ value: String?) -> String? {
        guard let token = sanitizedString(value) else { return nil }
        guard !looksLikeAppLabel(token), !isTimeLikeLabel(token), !isActionLabel(token) else {
            return nil
        }
        return token
    }

    private func cleanedPreviewLabel(_ value: String?, senderName: String?) -> String? {
        guard var preview = sanitizedString(value) else { return nil }
        guard !looksLikeAppLabel(preview), !isTimeLikeLabel(preview), !isActionLabel(preview) else {
            return nil
        }

        if let senderName {
            let senderPrefix = "\(senderName):"
            if preview.lowercased().hasPrefix(senderPrefix.lowercased()) {
                preview = String(preview.dropFirst(senderPrefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if preview.localizedCaseInsensitiveCompare(senderName) == .orderedSame {
                return nil
            }
        }

        return preview.isEmpty ? nil : preview
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
        let normalized = normalizedNotification(notification)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.recentNotifications = self.recentNotifications.map { self.normalizedNotification($0) }
            if let latest = self.latestNotification {
                self.latestNotification = self.normalizedNotification(latest)
            }

            guard !self.shouldSuppressIncomingNotification(normalized) else {
                return
            }

            // Merge near-identical WhatsApp notifications coming from different
            // ingestion paths (web bridge, delivered center, log observer).
            var mergedNotification = normalized
            if let duplicateIndex = self.duplicateNotificationIndex(for: normalized) {
                mergedNotification = self.mergeDuplicateNotification(
                    existing: self.recentNotifications[duplicateIndex],
                    incoming: normalized
                )
                self.recentNotifications.remove(at: duplicateIndex)
            }

            self.latestNotification = mergedNotification
            self.recentNotifications.removeAll { $0.sourceID == mergedNotification.sourceID }
            self.recentNotifications.insert(mergedNotification, at: 0)
            if self.recentNotifications.count > self.maxNotifications {
                self.recentNotifications.removeLast()
            }
            AppState.shared.showHUD(module: .notifications)
        }
    }

    func updateNotificationAvatar(sourceID: String, avatarURL: String) {
        guard let cleanedAvatarURL = cleanText(avatarURL) else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            if let latest = self.latestNotification,
               latest.sourceID == sourceID,
               latest.avatarURL != cleanedAvatarURL {
                self.latestNotification = self.notification(
                    from: latest,
                    replacingAvatarURL: cleanedAvatarURL
                )
            }

            guard let index = self.recentNotifications.firstIndex(where: { $0.sourceID == sourceID }),
                  self.recentNotifications[index].avatarURL != cleanedAvatarURL else {
                return
            }

            self.recentNotifications[index] = self.notification(
                from: self.recentNotifications[index],
                replacingAvatarURL: cleanedAvatarURL
            )
        }
    }

    func clearNotification(_ id: String) {
        if let dismissedNotification = recentNotifications.first(where: { $0.id == id })
            ?? (latestNotification?.id == id ? latestNotification : nil) {
            rememberDismissedNotification(dismissedNotification)
        }

        recentNotifications.removeAll { $0.id == id }
        if latestNotification?.id == id {
            latestNotification = recentNotifications.first
        }
    }

    func clearAll() {
        let notificationsToDismiss = Dictionary(
            uniqueKeysWithValues: (recentNotifications + [latestNotification].compactMap { $0 }).map { ($0.sourceID, $0) }
        ).map(\.value)
        notificationsToDismiss.forEach(rememberDismissedNotification)
        recentNotifications.removeAll()
        latestNotification = nil
    }

    private func normalizedNotification(_ notification: IslandNotification) -> IslandNotification {
        let title = cleanText(notification.title)
        let body = cleanText(notification.body)
        let senderName = cleanText(notification.senderName)
        let previewText = cleanText(notification.previewText)
        let appName = cleanText(notification.appName) ?? "Notification"

        let resolvedTitle = senderName ?? title ?? appName
        let resolvedPreview = previewText ?? body

        return IslandNotification(
            sourceID: notification.sourceID,
            appName: appName,
            bundleIdentifier: notification.bundleIdentifier,
            appIcon: notification.appIcon,
            appIconURL: cleanText(notification.appIconURL),
            title: resolvedTitle,
            body: resolvedPreview ?? "",
            senderName: senderName,
            previewText: resolvedPreview,
            avatarURL: cleanText(notification.avatarURL),
            timestamp: notification.timestamp
        )
    }

    private func notification(
        from notification: IslandNotification,
        replacingAvatarURL avatarURL: String?
    ) -> IslandNotification {
        IslandNotification(
            sourceID: notification.sourceID,
            appName: notification.appName,
            bundleIdentifier: notification.bundleIdentifier,
            appIcon: notification.appIcon,
            appIconURL: notification.appIconURL,
            title: notification.title,
            body: notification.body,
            senderName: notification.senderName,
            previewText: notification.previewText,
            avatarURL: avatarURL,
            timestamp: notification.timestamp
        )
    }

    private func mergeDuplicateNotification(
        existing: IslandNotification,
        incoming: IslandNotification
    ) -> IslandNotification {
        let preferred = preferredNotification(between: existing, and: incoming)
        let secondary = preferred.sourceID == existing.sourceID ? incoming : existing
        let preserveExistingSourceID = existing.sourceID.hasPrefix("whatsapp-web:") && !incoming.sourceID.hasPrefix("whatsapp-web:")
        let mergedSourceID: String

        if preserveExistingSourceID {
            mergedSourceID = existing.sourceID
        } else {
            let preferredPriority = sourcePriority(for: preferred.sourceID)
            let secondaryPriority = sourcePriority(for: secondary.sourceID)
            if preferredPriority > secondaryPriority {
                mergedSourceID = preferred.sourceID
            } else if secondaryPriority > preferredPriority {
                mergedSourceID = secondary.sourceID
            } else {
                mergedSourceID = preferred.sourceID
            }
        }

        return IslandNotification(
            sourceID: mergedSourceID,
            appName: preferred.appName,
            bundleIdentifier: preferred.bundleIdentifier ?? secondary.bundleIdentifier,
            appIcon: preferred.appIcon,
            appIconURL: preferred.appIconURL ?? secondary.appIconURL,
            title: preferred.title,
            body: preferred.body.isEmpty ? secondary.body : preferred.body,
            senderName: preferred.senderName ?? secondary.senderName,
            previewText: preferred.previewText ?? secondary.previewText,
            avatarURL: preferred.avatarURL ?? secondary.avatarURL,
            timestamp: incoming.timestamp >= existing.timestamp ? incoming.timestamp : existing.timestamp
        )
    }

    private func duplicateNotificationIndex(for incoming: IslandNotification) -> Int? {
        recentNotifications.firstIndex { existing in
            notificationsMatch(existing, incoming)
        }
    }

    private func notificationsMatch(_ existing: IslandNotification, _ incoming: IslandNotification) -> Bool {
        if existing.sourceID == incoming.sourceID {
            return true
        }

        if existing.appName.localizedCaseInsensitiveCompare(incoming.appName) == .orderedSame &&
            existing.title == incoming.title &&
            existing.body == incoming.body &&
            abs(existing.timestamp.timeIntervalSince(incoming.timestamp)) <= 15 {
            return true
        }

        guard isWhatsAppNotification(existing), isWhatsAppNotification(incoming) else {
            return false
        }

        let timeDelta = abs(existing.timestamp.timeIntervalSince(incoming.timestamp))
        guard timeDelta <= 8 else {
            return false
        }

        if isLowInformationWhatsApp(existing) && notificationQualityScore(incoming) > notificationQualityScore(existing) {
            return true
        }

        if isLowInformationWhatsApp(incoming) && notificationQualityScore(existing) > notificationQualityScore(incoming) {
            return true
        }

        return false
    }

    private func shouldSuppressIncomingNotification(_ notification: IslandNotification) -> Bool {
        pruneDismissedNotifications()

        if dismissedNotifications.contains(where: { $0.sourceID == notification.sourceID }) {
            return true
        }

        if dismissedNotifications.contains(where: { dismissed in
            notificationsAreSemanticallyEquivalent(notification, dismissed: dismissed)
        }) {
            return true
        }

        guard isLowInformationWhatsApp(notification) else {
            return false
        }

        let richerExistingNotification = notificationCandidatesForSuppression.contains { existing in
            guard isWhatsAppNotification(existing) else { return false }
            guard notificationQualityScore(existing) > notificationQualityScore(notification) else { return false }
            return abs(existing.timestamp.timeIntervalSince(notification.timestamp)) <= lowInformationSuppressionWindow
        }
        if richerExistingNotification {
            return true
        }

        return dismissedNotifications.contains { dismissed in
            dismissed.appName.localizedCaseInsensitiveCompare("WhatsApp") == .orderedSame &&
            dismissed.qualityScore > notificationQualityScore(notification) &&
            abs(dismissed.timestamp.timeIntervalSince(notification.timestamp)) <= lowInformationSuppressionWindow
        }
    }

    private var notificationCandidatesForSuppression: [IslandNotification] {
        if let latestNotification {
            return [latestNotification] + recentNotifications
        }
        return recentNotifications
    }

    private func notificationsAreSemanticallyEquivalent(
        _ notification: IslandNotification,
        dismissed: DismissedNotificationRecord
    ) -> Bool {
        guard notification.appName.localizedCaseInsensitiveCompare(dismissed.appName) == .orderedSame else {
            return false
        }

        let preview = cleanText(notification.previewText) ?? cleanText(notification.body)
        let senderName = cleanText(notification.senderName)

        if let dismissedPreview = dismissed.previewText,
           let preview,
           dismissedPreview.localizedCaseInsensitiveCompare(preview) == .orderedSame {
            return true
        }

        if let dismissedSenderName = dismissed.senderName,
           let senderName,
           dismissedSenderName.localizedCaseInsensitiveCompare(senderName) == .orderedSame,
           abs(dismissed.timestamp.timeIntervalSince(notification.timestamp)) <= lowInformationSuppressionWindow {
            return true
        }

        return false
    }

    private func rememberDismissedNotification(_ notification: IslandNotification) {
        pruneDismissedNotifications()
        dismissedNotifications.removeAll { $0.sourceID == notification.sourceID }
        dismissedNotifications.append(
            DismissedNotificationRecord(
                sourceID: notification.sourceID,
                appName: notification.appName,
                senderName: cleanText(notification.senderName),
                previewText: cleanText(notification.previewText) ?? cleanText(notification.body),
                timestamp: notification.timestamp,
                dismissedAt: Date(),
                qualityScore: notificationQualityScore(notification)
            )
        )

        if dismissedNotifications.count > maxDismissedNotifications {
            dismissedNotifications.removeFirst(dismissedNotifications.count - maxDismissedNotifications)
        }
    }

    private func pruneDismissedNotifications(now: Date = Date()) {
        dismissedNotifications.removeAll { now.timeIntervalSince($0.dismissedAt) > dismissedNotificationRetention }
    }

    private func preferredNotification(
        between existing: IslandNotification,
        and incoming: IslandNotification
    ) -> IslandNotification {
        let existingScore = notificationQualityScore(existing)
        let incomingScore = notificationQualityScore(incoming)

        if incomingScore != existingScore {
            return incomingScore > existingScore ? incoming : existing
        }

        let existingPriority = sourcePriority(for: existing.sourceID)
        let incomingPriority = sourcePriority(for: incoming.sourceID)
        if incomingPriority != existingPriority {
            return incomingPriority > existingPriority ? incoming : existing
        }

        return incoming.timestamp >= existing.timestamp ? incoming : existing
    }

    private func notificationQualityScore(_ notification: IslandNotification) -> Int {
        var score = 0

        if let senderName = cleanText(notification.senderName), !looksLikeAppLabel(senderName) {
            score += 4
        }

        if let previewText = cleanText(notification.previewText) ?? cleanText(notification.body),
           !looksLikeAppLabel(previewText) {
            score += 5
            if previewText.count >= 8 {
                score += 1
            }
        }

        if let title = cleanText(notification.title), !looksLikeAppLabel(title) {
            score += 2
        }

        if cleanText(notification.avatarURL) != nil {
            score += 1
        }

        score += sourcePriority(for: notification.sourceID)
        return score
    }

    private func sourcePriority(for sourceID: String) -> Int {
        if sourceID.hasPrefix("whatsapp-web:") {
            return 6
        }
        if sourceID.hasPrefix("extension:") {
            return 5
        }
        if sourceID.hasPrefix("delivered:") {
            return 3
        }
        if sourceID.hasPrefix("whatsapp-log:") {
            return 2
        }
        return 1
    }

    private func isWhatsAppNotification(_ notification: IslandNotification) -> Bool {
        notification.appName.localizedCaseInsensitiveContains("whatsapp")
            || (notification.bundleIdentifier?.localizedCaseInsensitiveContains("whatsapp") ?? false)
            || notification.sourceID.localizedCaseInsensitiveContains("whatsapp")
    }

    private func isLowInformationWhatsApp(_ notification: IslandNotification) -> Bool {
        guard isWhatsAppNotification(notification) else { return false }
        let senderName = cleanText(notification.senderName)
        let previewText = cleanText(notification.previewText) ?? cleanText(notification.body)
        let title = cleanText(notification.title)
        return senderName == nil && previewText == nil && (title == nil || looksLikeAppLabel(title!))
    }

    private func cleanText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        if lowered == "undefined" || lowered == "null" || lowered == "(null)" {
            return nil
        }
        return trimmed
    }

    deinit {
        whatsappLogMonitorTimer?.cancel()
        whatsappLogMonitorTimer = nil
        deliveredNotificationMonitorTimer?.cancel()
        deliveredNotificationMonitorTimer = nil
        DistributedNotificationCenter.default().removeObserver(self)
    }
}
