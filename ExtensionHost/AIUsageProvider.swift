import Foundation

private struct CodexUsageWindow {
    let usedPercent: Double
    let remainingPercent: Double
    let windowMinutes: Int
    let resetsAt: Int?

    var dictionary: [String: Any] {
        [
            "usedPercent": usedPercent,
            "remainingPercent": remainingPercent,
            "windowMinutes": windowMinutes,
            "windowLabel": windowLabel,
            "resetsAt": resetsAt ?? NSNull(),
        ]
    }

    private var windowLabel: String {
        if windowMinutes % 1440 == 0 {
            return "\(windowMinutes / 1440)d"
        }
        if windowMinutes % 60 == 0 {
            return "\(windowMinutes / 60)h"
        }
        return "\(windowMinutes)m"
    }
}

private struct CodexUsageSnapshot {
    let primary: CodexUsageWindow?
    let secondary: CodexUsageWindow?
    let planType: String?
    let hasCredits: Bool
    let unlimited: Bool

    var dictionary: [String: Any] {
        [
            "available": true,
            "primary": primary?.dictionary ?? NSNull(),
            "secondary": secondary?.dictionary ?? NSNull(),
            "planType": planType ?? NSNull(),
            "hasCredits": hasCredits,
            "unlimited": unlimited,
        ]
    }
}

private struct ClaudeUsageSnapshot {
    let status: String
    let hoursTillReset: Int?
    let resetAt: Int?
    let model: String?
    let updatedAt: Int
    let unifiedRateLimitFallbackAvailable: Bool

    var dictionary: [String: Any] {
        [
            "available": true,
            "status": status,
            "statusLabel": statusLabel,
            "hoursTillReset": hoursTillReset ?? NSNull(),
            "resetAt": resetAt ?? NSNull(),
            "model": model ?? NSNull(),
            "updatedAt": updatedAt,
            "unifiedRateLimitFallbackAvailable": unifiedRateLimitFallbackAvailable,
            "isBlocked": status == "rejected",
        ]
    }

    private var statusLabel: String {
        switch status {
        case "allowed":
            return "Available"
        case "allowed_warning":
            return "Low"
        case "rejected":
            return "Blocked"
        default:
            return "Unknown"
        }
    }
}

private struct AIUsageSnapshot {
    let updatedAt: Int
    let codex: CodexUsageSnapshot?
    let claude: ClaudeUsageSnapshot?

    var dictionary: [String: Any] {
        [
            "updatedAt": updatedAt,
            "codex": codex?.dictionary ?? ["available": false],
            "claude": claude?.dictionary ?? ["available": false],
        ]
    }
}

final class AIUsageProvider {
    static let shared = AIUsageProvider()

    private let fileManager = FileManager.default
    private let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    private let refreshInterval: TimeInterval = 20
    private let iso8601WithFractionalSeconds: ISO8601DateFormatter
    private let iso8601WithoutFractionalSeconds: ISO8601DateFormatter

    private var cachedSnapshot: AIUsageSnapshot?
    private var lastRefreshDate: Date?

    private init() {
        let withFractionalSeconds = ISO8601DateFormatter()
        withFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        iso8601WithFractionalSeconds = withFractionalSeconds

        let withoutFractionalSeconds = ISO8601DateFormatter()
        withoutFractionalSeconds.formatOptions = [.withInternetDateTime]
        iso8601WithoutFractionalSeconds = withoutFractionalSeconds
    }

    func snapshotDictionary() -> [String: Any] {
        snapshot().dictionary
    }

    private func snapshot() -> AIUsageSnapshot {
        let now = Date()
        if let cachedSnapshot,
           let lastRefreshDate,
           now.timeIntervalSince(lastRefreshDate) < refreshInterval {
            return cachedSnapshot
        }

        let snapshot = AIUsageSnapshot(
            updatedAt: Int(now.timeIntervalSince1970),
            codex: loadCodexUsage(),
            claude: loadClaudeUsage()
        )

        cachedSnapshot = snapshot
        lastRefreshDate = now
        return snapshot
    }

    private func loadCodexUsage() -> CodexUsageSnapshot? {
        let sessionsDirectory = homeDirectory
            .appending(path: ".codex", directoryHint: .isDirectory)
            .appending(path: "sessions", directoryHint: .isDirectory)

        let candidateFiles = recentFiles(
            at: sessionsDirectory,
            limit: 20
        ) { url in
            url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-")
        }

        var exactMatch: (date: Date, usage: CodexUsageSnapshot)?
        var fallbackMatch: (date: Date, usage: CodexUsageSnapshot)?

        for fileURL in candidateFiles {
            guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue
            }

            for line in contents.split(whereSeparator: \.isNewline) {
                guard line.contains("\"token_count\""),
                      line.contains("\"rate_limits\""),
                      let event = jsonDictionary(from: String(line)),
                      let payload = event["payload"] as? [String: Any],
                      (payload["type"] as? String) == "token_count",
                      let rateLimits = payload["rate_limits"] as? [String: Any],
                      let usage = parseCodexUsage(from: rateLimits) else {
                    continue
                }

                let timestamp = date(from: event["timestamp"] as? String) ?? .distantPast
                if let limitID = rateLimits["limit_id"] as? String {
                    guard limitID == "codex" else { continue }
                    if exactMatch?.date ?? .distantPast < timestamp {
                        exactMatch = (timestamp, usage)
                    }
                } else if fallbackMatch?.date ?? .distantPast < timestamp {
                    fallbackMatch = (timestamp, usage)
                }
            }
        }

        return exactMatch?.usage ?? fallbackMatch?.usage
    }

    private func loadClaudeUsage() -> ClaudeUsageSnapshot? {
        let telemetryDirectory = homeDirectory
            .appending(path: ".claude", directoryHint: .isDirectory)
            .appending(path: "telemetry", directoryHint: .isDirectory)

        let candidateFiles = recentFiles(
            at: telemetryDirectory,
            limit: 12
        ) { url in
            url.pathExtension == "json" && url.lastPathComponent.hasPrefix("1p_failed_events.")
        }

        var latestMatch: (date: Date, usage: ClaudeUsageSnapshot)?

        for fileURL in candidateFiles {
            guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue
            }

            for line in contents.split(whereSeparator: \.isNewline) {
                guard line.contains("tengu_claudeai_limits_status_changed"),
                      let event = jsonDictionary(from: String(line)),
                      let eventData = event["event_data"] as? [String: Any],
                      (eventData["event_name"] as? String) == "tengu_claudeai_limits_status_changed",
                      let metadataString = eventData["additional_metadata"] as? String,
                      let metadata = jsonDictionary(from: metadataString),
                      let status = metadata["status"] as? String else {
                    continue
                }

                let timestamp = date(from: eventData["client_timestamp"] as? String) ?? .distantPast
                let hoursTillReset = intValue(metadata["hoursTillReset"])
                let resetAt: Int?
                if let hoursTillReset {
                    resetAt = Int(timestamp.addingTimeInterval(TimeInterval(hoursTillReset * 3600)).timeIntervalSince1970)
                } else {
                    resetAt = nil
                }

                let usage = ClaudeUsageSnapshot(
                    status: status,
                    hoursTillReset: hoursTillReset,
                    resetAt: resetAt,
                    model: eventData["model"] as? String,
                    updatedAt: Int(timestamp.timeIntervalSince1970),
                    unifiedRateLimitFallbackAvailable: boolValue(metadata["unifiedRateLimitFallbackAvailable"]) ?? false
                )

                if latestMatch?.date ?? .distantPast < timestamp {
                    latestMatch = (timestamp, usage)
                }
            }
        }

        return latestMatch?.usage
    }

    private func parseCodexUsage(from rateLimits: [String: Any]) -> CodexUsageSnapshot? {
        let primary = parseCodexWindow(rateLimits["primary"])
        let secondary = parseCodexWindow(rateLimits["secondary"])
        guard primary != nil || secondary != nil else {
            return nil
        }

        let credits = rateLimits["credits"] as? [String: Any]
        return CodexUsageSnapshot(
            primary: primary,
            secondary: secondary,
            planType: rateLimits["plan_type"] as? String,
            hasCredits: boolValue(credits?["has_credits"]) ?? false,
            unlimited: boolValue(credits?["unlimited"]) ?? false
        )
    }

    private func parseCodexWindow(_ rawValue: Any?) -> CodexUsageWindow? {
        guard let dictionary = rawValue as? [String: Any],
              let usedPercent = doubleValue(dictionary["used_percent"]),
              let windowMinutes = intValue(dictionary["window_minutes"]) else {
            return nil
        }

        return CodexUsageWindow(
            usedPercent: boundedPercent(usedPercent),
            remainingPercent: boundedPercent(100 - usedPercent),
            windowMinutes: windowMinutes,
            resetsAt: intValue(dictionary["resets_at"])
        )
    }

    private func recentFiles(
        at rootURL: URL,
        limit: Int,
        include: (URL) -> Bool
    ) -> [URL] {
        guard fileManager.fileExists(atPath: rootURL.path),
              let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        var files: [(url: URL, modificationDate: Date)] = []
        for case let fileURL as URL in enumerator {
            guard include(fileURL),
                  let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true else {
                continue
            }

            files.append((fileURL, values.contentModificationDate ?? .distantPast))
        }

        return files
            .sorted { lhs, rhs in
                if lhs.modificationDate == rhs.modificationDate {
                    return lhs.url.path > rhs.url.path
                }
                return lhs.modificationDate > rhs.modificationDate
            }
            .prefix(limit)
            .map(\.url)
    }

    private func jsonDictionary(from string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    private func date(from string: String?) -> Date? {
        guard let string else { return nil }
        return iso8601WithFractionalSeconds.date(from: string) ?? iso8601WithoutFractionalSeconds.date(from: string)
    }

    private func boolValue(_ rawValue: Any?) -> Bool? {
        switch rawValue {
        case let value as Bool:
            return value
        case let value as NSNumber:
            return value.boolValue
        default:
            return nil
        }
    }

    private func intValue(_ rawValue: Any?) -> Int? {
        switch rawValue {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }

    private func doubleValue(_ rawValue: Any?) -> Double? {
        switch rawValue {
        case let value as Double:
            return value
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            return Double(value)
        default:
            return nil
        }
    }

    private func boundedPercent(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }
}
