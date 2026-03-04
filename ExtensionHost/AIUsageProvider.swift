import Foundation

enum AIUsageProvider {
    private static let cacheTTL: TimeInterval = 60
    private static var cachedSnapshot: [String: Any]?
    private static var cachedAt: Date?
    private static let cacheLock = NSLock()

    static func snapshot() -> [String: Any] {
        let nowDate = Date()

        cacheLock.lock()
        if let cachedAt,
           let cachedSnapshot,
           nowDate.timeIntervalSince(cachedAt) < cacheTTL {
            cacheLock.unlock()
            return cachedSnapshot
        }
        cacheLock.unlock()

        let now = Int(nowDate.timeIntervalSince1970)
        let payload: [String: Any] = [
            "updatedAt": now,
            "codex": buildCodexPayload(updatedAt: now),
            "claude": buildClaudePayload(updatedAt: now)
        ]

        cacheLock.lock()
        cachedAt = nowDate
        cachedSnapshot = payload
        cacheLock.unlock()

        return payload
    }

    // MARK: - Codex

    private static func buildCodexPayload(updatedAt: Int) -> [String: Any] {
        if let localSummary = loadJSONDictionary(fromCandidates: homePathCandidates([
            ".codex/usage-summary.json",
            ".codex/usage/summary.json"
        ])) {
            return buildCodexPayloadFromLocalSummary(localSummary, updatedAt: updatedAt)
        }

        if let oauthPayload = loadCodexPayloadFromOAuthAPI(updatedAt: updatedAt) {
            return oauthPayload
        }

        // Last fallback: if auth exists we still mark as available to avoid N/A UI.
        let hasAuth = loadCodexAccessToken() != nil
        return [
            "available": hasAuth,
            "primary": NSNull(),
            "secondary": NSNull(),
            "planType": NSNull(),
            "hasCredits": false,
            "unlimited": false,
            "source": hasAuth ? "auth-token" : "unavailable",
            "updatedAt": updatedAt
        ]
    }

    private static func buildCodexPayloadFromLocalSummary(_ data: [String: Any], updatedAt: Int) -> [String: Any] {
        [
            "available": true,
            "primary": data["primary"] ?? NSNull(),
            "secondary": data["secondary"] ?? NSNull(),
            "planType": data["planType"] ?? NSNull(),
            "hasCredits": data["hasCredits"] as? Bool ?? false,
            "unlimited": data["unlimited"] as? Bool ?? false,
            "source": "local-summary",
            "updatedAt": data["updatedAt"] ?? updatedAt
        ]
    }

    private static func loadCodexPayloadFromOAuthAPI(updatedAt: Int) -> [String: Any]? {
        guard let token = loadCodexAccessToken(),
              let url = URL(string: "https://chatgpt.com/backend-api/wham/usage"),
              let response = fetchJSON(url: url, bearerToken: token, timeout: 3.0) else {
            return nil
        }

        let rateLimit = response["rate_limit"] as? [String: Any]
        let primary = mapCodexWindow(rateLimit?["primary_window"])
        let secondary = mapCodexWindow(rateLimit?["secondary_window"])
        let credits = response["credits"] as? [String: Any]

        return [
            "available": true,
            "primary": primary ?? NSNull(),
            "secondary": secondary ?? NSNull(),
            "planType": response["plan_type"] ?? NSNull(),
            "hasCredits": credits?["has_credits"] as? Bool ?? false,
            "unlimited": credits?["unlimited"] as? Bool ?? false,
            "source": "oauth-api",
            "updatedAt": updatedAt
        ]
    }

    private static func mapCodexWindow(_ value: Any?) -> [String: Any]? {
        guard let window = value as? [String: Any] else {
            return nil
        }

        let usedPercent = asDouble(window["used_percent"])
        let remainingPercent = max(0, 100 - usedPercent)
        let limitWindowSeconds = Int(asDouble(window["limit_window_seconds"]))
        let windowMinutes = max(1, limitWindowSeconds / 60)

        return [
            "usedPercent": usedPercent,
            "remainingPercent": remainingPercent,
            "windowMinutes": windowMinutes,
            "windowLabel": codexWindowLabel(seconds: limitWindowSeconds),
            "resetsAt": window["reset_at"] ?? NSNull()
        ]
    }

    private static func codexWindowLabel(seconds: Int) -> String {
        if seconds % 3600 == 0 {
            return "\(seconds / 3600)h"
        }
        return "\(max(1, seconds / 60))m"
    }

    private static func loadCodexAccessToken() -> String? {
        for authPath in homePathCandidates([".codex/auth.json"]) {
            let authURL = URL(fileURLWithPath: authPath)
            guard FileManager.default.fileExists(atPath: authURL.path),
                  let data = try? Data(contentsOf: authURL),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tokens = object["tokens"] as? [String: Any],
                  let accessToken = tokens["access_token"] as? String,
                  !accessToken.isEmpty else {
                continue
            }
            return accessToken
        }
        return nil
    }

    // MARK: - Claude

    private static func buildClaudePayload(updatedAt: Int) -> [String: Any] {
        if let localSummary = loadJSONDictionary(fromCandidates: homePathCandidates([
            ".claude/usage-summary.json",
            ".config/claude/usage-summary.json"
        ])) {
            return buildClaudePayloadFromLocalSummary(localSummary, updatedAt: updatedAt)
        }

        if let statsPayload = buildClaudePayloadFromStatsCache(updatedAt: updatedAt) {
            return statsPayload
        }

        return [
            "available": false,
            "status": NSNull(),
            "statusLabel": NSNull(),
            "hoursTillReset": NSNull(),
            "resetAt": NSNull(),
            "model": NSNull(),
            "updatedAt": updatedAt,
            "unifiedRateLimitFallbackAvailable": false,
            "isBlocked": false,
            "source": "unavailable"
        ]
    }

    private static func buildClaudePayloadFromLocalSummary(_ data: [String: Any], updatedAt: Int) -> [String: Any] {
        [
            "available": true,
            "status": data["status"] ?? NSNull(),
            "statusLabel": data["statusLabel"] ?? NSNull(),
            "hoursTillReset": data["hoursTillReset"] ?? NSNull(),
            "resetAt": data["resetAt"] ?? NSNull(),
            "model": data["model"] ?? NSNull(),
            "updatedAt": data["updatedAt"] ?? updatedAt,
            "unifiedRateLimitFallbackAvailable": data["unifiedRateLimitFallbackAvailable"] as? Bool ?? false,
            "isBlocked": data["isBlocked"] as? Bool ?? false,
            "source": "local-summary"
        ]
    }

    private static func buildClaudePayloadFromStatsCache(updatedAt: Int) -> [String: Any]? {
        for statsPath in homePathCandidates([
            ".claude/stats-cache.json",
            ".config/claude/stats-cache.json"
        ]) {
            let statsURL = URL(fileURLWithPath: statsPath)
            guard FileManager.default.fileExists(atPath: statsURL.path),
                  let data = try? Data(contentsOf: statsURL),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let modificationDate = (try? statsURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let fileUpdatedAt = Int((modificationDate ?? Date()).timeIntervalSince1970)
            let ageHours = max(0, Int(Date().timeIntervalSince1970 - TimeInterval(fileUpdatedAt)) / 3600)
            let isFresh = ageHours <= 36

            return [
                "available": true,
                "status": isFresh ? "allowed" : "allowed_warning",
                "statusLabel": isFresh ? "From local Claude stats cache" : "Claude stats cache may be stale",
                "hoursTillReset": NSNull(),
                "resetAt": NSNull(),
                "model": preferredClaudeModel(from: object) ?? NSNull(),
                "updatedAt": fileUpdatedAt,
                "unifiedRateLimitFallbackAvailable": true,
                "isBlocked": false,
                "source": "stats-cache"
            ]
        }
        return nil
    }

    private static func preferredClaudeModel(from stats: [String: Any]) -> String? {
        guard let modelUsage = stats["modelUsage"] as? [String: Any], !modelUsage.isEmpty else {
            return nil
        }

        var best: (name: String, score: Double)?

        for (modelName, payload) in modelUsage {
            guard let payload = payload as? [String: Any] else { continue }
            let inputTokens = asDouble(payload["inputTokens"])
            let outputTokens = asDouble(payload["outputTokens"])
            let cacheRead = asDouble(payload["cacheReadInputTokens"])
            let score = inputTokens + outputTokens + cacheRead
            if best == nil || score > (best?.score ?? 0) {
                best = (name: modelName, score: score)
            }
        }

        return best?.name
    }

    // MARK: - Shared

    private static func fetchJSON(url: URL, bearerToken: String, timeout: TimeInterval) -> [String: Any]? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("DynamicIsland/1.0", forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        var parsed: [String: Any]?

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            guard error == nil,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            parsed = object
        }

        task.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 0.3)
        return parsed
    }

    private static func asDouble(_ value: Any?) -> Double {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String, let parsed = Double(value) { return parsed }
        return 0
    }

    private static func loadJSONDictionary(fromCandidates candidates: [String]) -> [String: Any]? {
        for candidate in candidates {
            let url = URL(fileURLWithPath: candidate)
            guard FileManager.default.fileExists(atPath: url.path) else {
                continue
            }

            do {
                let data = try Data(contentsOf: url)
                let object = try JSONSerialization.jsonObject(with: data)
                if let dictionary = object as? [String: Any] {
                    return dictionary
                }
            } catch {
                continue
            }
        }

        return nil
    }

    private static func homePathCandidates(_ relativePaths: [String]) -> [String] {
        var basePaths: [String] = []

        let currentUserHome = FileManager.default.homeDirectoryForCurrentUser.path
        if !currentUserHome.isEmpty {
            basePaths.append(currentUserHome)
        }

        let nsHome = NSHomeDirectory()
        if !nsHome.isEmpty {
            basePaths.append(nsHome)
        }

        if let envHome = ProcessInfo.processInfo.environment["HOME"], !envHome.isEmpty {
            basePaths.append(envHome)
        }

        var candidates: [String] = []
        for basePath in uniquePreservingOrder(basePaths) {
            let baseURL = URL(fileURLWithPath: basePath, isDirectory: true)
            for relativePath in relativePaths {
                candidates.append(baseURL.appendingPathComponent(relativePath).path)
            }
        }

        return uniquePreservingOrder(candidates)
    }

    private static func uniquePreservingOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(values.count)

        for value in values where !value.isEmpty {
            if seen.insert(value).inserted {
                result.append(value)
            }
        }

        return result
    }
}
