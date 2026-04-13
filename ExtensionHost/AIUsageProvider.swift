import Foundation
#if os(macOS)
import Security
#endif

enum AIUsageProvider {
    private static let cacheTTL: TimeInterval = 300
    private static let claudeKeychainAccessStateDefaultsKey = "aiUsage.claude.keychainAccessState"
    private static let claudeKeychainAccessDeniedAtDefaultsKey = "aiUsage.claude.keychainAccessDeniedAt"
    private static let claudeKeychainAccessRetryInterval: TimeInterval = 24 * 60 * 60
    private static var cachedSnapshot: [String: Any]?
    private static var cachedAt: Date?
    private static let cacheLock = NSLock()
    private static var isRefreshing = false

    private enum ClaudeKeychainAccessState: String {
        case unknown
        case allowed
        case denied
    }

    // Returns cached data immediately (never blocks). Triggers a background
    // refresh if the cache is missing or stale. This prevents the semaphore-
    // blocked network calls in fetchJSON from freezing the main thread.
    static func snapshot() -> [String: Any] {
        let nowDate = Date()

        cacheLock.lock()
        let existing = cachedSnapshot
        let age = cachedAt.map { nowDate.timeIntervalSince($0) } ?? cacheTTL
        cacheLock.unlock()

        if existing == nil || age >= cacheTTL {
            triggerBackgroundRefresh()
        }

        return existing ?? [
            "updatedAt": Int(nowDate.timeIntervalSince1970),
            "codex": ["available": false, "source": "loading"] as [String: Any],
            "claude": ["available": false, "source": "loading"] as [String: Any],
            "gemini": ["available": false, "source": "loading"] as [String: Any]
        ]
    }

    private static func triggerBackgroundRefresh() {
        cacheLock.lock()
        guard !isRefreshing else {
            cacheLock.unlock()
            return
        }
        isRefreshing = true
        cacheLock.unlock()

        DispatchQueue.global(qos: .utility).async {
            let nowDate = Date()
            let now = Int(nowDate.timeIntervalSince1970)
            let payload: [String: Any] = [
                "updatedAt": now,
                "codex": buildCodexPayload(updatedAt: now),
                "claude": buildClaudePayload(updatedAt: now),
                "gemini": buildGeminiPayload(updatedAt: now)
            ]

            cacheLock.lock()
            cachedAt = nowDate
            cachedSnapshot = payload
            isRefreshing = false
            cacheLock.unlock()
        }
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

        if let oauthPayload = loadClaudePayloadFromOAuthAPI(updatedAt: updatedAt) {
            return oauthPayload
        }

        if let statsPayload = buildClaudePayloadFromStatsCache(updatedAt: updatedAt) {
            return statsPayload
        }

        return [
            "available": false,
            "status": NSNull(),
            "statusLabel": NSNull(),
            "remainingPercent": NSNull(),
            "weeklyRemainingPercent": NSNull(),
            "currentSessionRemainingPercent": NSNull(),
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
        let remainingPercent = claudeRemainingPercent(from: data)
        let weeklyRemainingPercent = claudeWeeklyRemainingPercent(from: data)
        let currentSessionRemainingPercent = claudeCurrentSessionRemainingPercent(from: data)
        var payload: [String: Any] = [
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
        payload["remainingPercent"] = remainingPercent ?? NSNull()
        payload["weeklyRemainingPercent"] = weeklyRemainingPercent ?? NSNull()
        payload["currentSessionRemainingPercent"] = currentSessionRemainingPercent ?? NSNull()
        return payload
    }

    private static func loadClaudePayloadFromOAuthAPI(updatedAt: Int) -> [String: Any]? {
        guard let accessToken = loadClaudeAccessToken(),
              let url = URL(string: "https://api.anthropic.com/api/oauth/usage"),
              let response = fetchJSON(
                url: url,
                bearerToken: accessToken,
                timeout: 3.0,
                extraHeaders: [
                    "anthropic-beta": "oauth-2025-04-20",
                    "Content-Type": "application/json"
                ]
              ) else {
            return nil
        }

        guard let sessionRemainingPercent = claudeCurrentSessionRemainingPercent(from: response) else {
            return nil
        }

        let weeklyRemainingPercent = claudeWeeklyRemainingPercent(from: response)
        let overallRemainingPercent = weeklyRemainingPercent.map { min(sessionRemainingPercent, $0) } ?? sessionRemainingPercent
        let status: String
        if overallRemainingPercent <= 0 {
            status = "rejected"
        } else if overallRemainingPercent <= 25 {
            status = "allowed_warning"
        } else {
            status = "allowed"
        }

        let resetAt = claudeResetAtISO8601(from: response)
        let hoursTillReset = claudeHoursUntilReset(fromISO8601: resetAt)
        let model = claudeOAuthPreferredModel(from: response)

        var payload: [String: Any] = [
            "available": true,
            "status": status,
            "statusLabel": "From Claude OAuth API",
            "hoursTillReset": hoursTillReset ?? NSNull(),
            "resetAt": resetAt ?? NSNull(),
            "model": model ?? NSNull(),
            "updatedAt": updatedAt,
            "unifiedRateLimitFallbackAvailable": false,
            "isBlocked": status == "rejected",
            "source": "oauth-api"
        ]
        payload["remainingPercent"] = overallRemainingPercent
        payload["weeklyRemainingPercent"] = weeklyRemainingPercent ?? NSNull()
        payload["currentSessionRemainingPercent"] = sessionRemainingPercent
        return payload
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
            let remainingPercent = claudeRemainingPercent(from: object)
            let weeklyRemainingPercent = claudeWeeklyRemainingPercent(from: object)
            let currentSessionRemainingPercent = claudeCurrentSessionRemainingPercent(from: object)

            var payload: [String: Any] = [
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
            payload["remainingPercent"] = remainingPercent ?? NSNull()
            payload["weeklyRemainingPercent"] = weeklyRemainingPercent ?? NSNull()
            payload["currentSessionRemainingPercent"] = currentSessionRemainingPercent ?? NSNull()
            return payload
        }
        return nil
    }

    private static func claudeRemainingPercent(from payload: [String: Any]) -> Double? {
        let sessionRemaining = claudeCurrentSessionRemainingPercent(from: payload)
        let weeklyRemaining = claudeWeeklyRemainingPercent(from: payload)
        if let sessionRemaining, let weeklyRemaining {
            return min(sessionRemaining, weeklyRemaining)
        }
        if let sessionRemaining {
            return sessionRemaining
        }
        if let weeklyRemaining {
            return weeklyRemaining
        }

        let candidates: [Any?] = [
            payload["remainingPercent"],
            payload["remaining_percent"],
            payload["percentRemaining"],
            payload["percentageRemaining"],
            payload["remaining"],
            payload["usageRemainingPercent"],
            payload["availablePercent"],
            payload["available_percent"]
        ]

        for candidate in candidates {
            if let value = asDoubleOrNil(candidate) {
                return max(0, min(100, value))
            }
        }

        if let usage = payload["usage"] as? [String: Any] {
            return claudeRemainingPercent(from: usage)
        }

        if let limits = payload["limits"] as? [String: Any] {
            return claudeRemainingPercent(from: limits)
        }

        if let rateLimit = payload["rateLimit"] as? [String: Any] {
            return claudeRemainingPercent(from: rateLimit)
        }

        return nil
    }

    private static func claudeWeeklyRemainingPercent(from payload: [String: Any]) -> Double? {
        for key in ["seven_day_sonnet", "seven_day", "seven_day_opus", "seven_day_oauth_apps"] {
            if let window = payload[key] as? [String: Any],
               let remaining = claudeRemainingFromUsageWindow(window) {
                return remaining
            }
        }

        let candidates: [Any?] = [
            payload["weeklyRemainingPercent"],
            payload["weekly_remaining_percent"],
            payload["weekRemainingPercent"],
            payload["weeklyPercentRemaining"],
            payload["weeklyRemaining"],
            payload["remainingPercentWeek"]
        ]
        for candidate in candidates {
            if let value = asDoubleOrNil(candidate) {
                return max(0, min(100, value))
            }
        }
        if let weekly = payload["weekly"] as? [String: Any] {
            return claudeWeeklyRemainingPercent(from: weekly)
        }
        if let usage = payload["usage"] as? [String: Any] {
            return claudeWeeklyRemainingPercent(from: usage)
        }
        if let limits = payload["limits"] as? [String: Any] {
            return claudeWeeklyRemainingPercent(from: limits)
        }
        return nil
    }

    private static func claudeCurrentSessionRemainingPercent(from payload: [String: Any]) -> Double? {
        if let window = payload["five_hour"] as? [String: Any],
           let remaining = claudeRemainingFromUsageWindow(window) {
            return remaining
        }

        let candidates: [Any?] = [
            payload["currentSessionRemainingPercent"],
            payload["current_session_remaining_percent"],
            payload["sessionRemainingPercent"],
            payload["session_percent_remaining"],
            payload["currentSessionPercentRemaining"],
            payload["sessionRemaining"],
            payload["remainingPercentCurrentSession"]
        ]
        for candidate in candidates {
            if let value = asDoubleOrNil(candidate) {
                return max(0, min(100, value))
            }
        }
        if let currentSession = payload["currentSession"] as? [String: Any] {
            return claudeCurrentSessionRemainingPercent(from: currentSession)
        }
        if let usage = payload["usage"] as? [String: Any] {
            return claudeCurrentSessionRemainingPercent(from: usage)
        }
        if let limits = payload["limits"] as? [String: Any] {
            return claudeCurrentSessionRemainingPercent(from: limits)
        }
        return nil
    }

    private static func claudeRemainingFromUsageWindow(_ window: [String: Any]) -> Double? {
        guard let utilization = asDoubleOrNil(window["utilization"]) else {
            return nil
        }
        return max(0, min(100, 100 - utilization))
    }

    private static func claudeResetAtISO8601(from payload: [String: Any]) -> String? {
        for key in ["five_hour", "seven_day_sonnet", "seven_day", "seven_day_opus", "seven_day_oauth_apps"] {
            if let window = payload[key] as? [String: Any],
               let resetAt = window["resets_at"] as? String,
               !resetAt.isEmpty {
                return resetAt
            }
        }
        return nil
    }

    private static func claudeHoursUntilReset(fromISO8601 resetAt: String?) -> Int? {
        guard let resetAt,
              let resetDate = parseISO8601Date(resetAt) else {
            return nil
        }
        let seconds = resetDate.timeIntervalSinceNow
        if seconds <= 0 {
            return 0
        }
        return Int(ceil(seconds / 3600))
    }

    private static func parseISO8601Date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func claudeOAuthPreferredModel(from payload: [String: Any]) -> String? {
        if payload["seven_day_sonnet"] != nil {
            return "sonnet"
        }
        if payload["seven_day_opus"] != nil {
            return "opus"
        }
        if payload["seven_day_oauth_apps"] != nil {
            return "oauth-apps"
        }
        return nil
    }

    private static func loadClaudeAccessToken() -> String? {
        let environment = ProcessInfo.processInfo.environment
        let envKeys = [
            "CLAUDE_CODE_OAUTH_ACCESS_TOKEN",
            "CLAUDE_OAUTH_ACCESS_TOKEN",
            "ANTHROPIC_OAUTH_ACCESS_TOKEN"
        ]
        for key in envKeys {
            if let token = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !token.isEmpty {
                return token
            }
        }

        if let token = loadClaudeAccessTokenFromCredentialsFile() {
            return token
        }

        #if os(macOS)
        if claudeKeychainAccessState() != .denied,
           let token = loadClaudeAccessTokenFromKeychain() {
            return token
        }
        #endif

        return nil
    }

    private static func loadClaudeAccessTokenFromCredentialsFile() -> String? {
        let credentialCandidates = homePathCandidates([
            ".claude/.credentials.json",
            ".claude/credentials.json",
            ".config/claude/.credentials.json",
            ".config/claude/credentials.json"
        ])

        for path in credentialCandidates {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let token = claudeAccessToken(fromJSONObject: object) else {
                continue
            }
            return token
        }

        return nil
    }

    private static func claudeAccessToken(fromJSONObject object: Any) -> String? {
        guard let token = findStringValue(
            in: object,
            keys: ["access_token", "accessToken"],
            depth: 0,
            maxDepth: 8
        ) else {
            return nil
        }

        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func findStringValue(
        in object: Any,
        keys: Set<String>,
        depth: Int,
        maxDepth: Int
    ) -> String? {
        if depth > maxDepth {
            return nil
        }

        if let dictionary = object as? [String: Any] {
            for key in keys {
                if let value = dictionary[key] as? String, !value.isEmpty {
                    return value
                }
            }

            for value in dictionary.values {
                if let nested = findStringValue(
                    in: value,
                    keys: keys,
                    depth: depth + 1,
                    maxDepth: maxDepth
                ) {
                    return nested
                }
            }
            return nil
        }

        if let array = object as? [Any] {
            for value in array {
                if let nested = findStringValue(
                    in: value,
                    keys: keys,
                    depth: depth + 1,
                    maxDepth: maxDepth
                ) {
                    return nested
                }
            }
        }

        return nil
    }

    #if os(macOS)
    private static func loadClaudeAccessTokenFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        updateClaudeKeychainAccessState(for: status)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        if let object = try? JSONSerialization.jsonObject(with: data),
           let token = claudeAccessToken(fromJSONObject: object) {
            return token
        }

        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }

        if let jsonData = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: jsonData),
           let token = claudeAccessToken(fromJSONObject: object) {
            return token
        }

        return nil
    }
    #endif

    private static func claudeKeychainAccessState() -> ClaudeKeychainAccessState {
        guard let rawValue = UserDefaults.standard.string(forKey: claudeKeychainAccessStateDefaultsKey),
              let state = ClaudeKeychainAccessState(rawValue: rawValue) else {
            return .unknown
        }

        guard state == .denied else {
            return state
        }

        guard let deniedAt = claudeKeychainAccessDeniedAt(),
              Date().timeIntervalSince(deniedAt) < claudeKeychainAccessRetryInterval else {
            // A stale denial should not suppress the prompt forever. If we do not
            // know when the user last denied, let the next foreground access retry.
            setClaudeKeychainAccessState(.unknown)
            return .unknown
        }

        return state
    }

    private static func setClaudeKeychainAccessState(_ state: ClaudeKeychainAccessState) {
        if state == .unknown {
            UserDefaults.standard.removeObject(forKey: claudeKeychainAccessStateDefaultsKey)
            UserDefaults.standard.removeObject(forKey: claudeKeychainAccessDeniedAtDefaultsKey)
        } else {
            UserDefaults.standard.set(state.rawValue, forKey: claudeKeychainAccessStateDefaultsKey)
            if state == .denied {
                UserDefaults.standard.set(Date(), forKey: claudeKeychainAccessDeniedAtDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: claudeKeychainAccessDeniedAtDefaultsKey)
            }
        }
    }

    private static func updateClaudeKeychainAccessState(for status: OSStatus) {
        switch status {
        case errSecSuccess:
            setClaudeKeychainAccessState(.allowed)
        #if os(macOS)
        case errSecAuthFailed, errSecUserCanceled:
            // Stop repeated OS keychain prompts after the user explicitly denies once.
            setClaudeKeychainAccessState(.denied)
        case errSecInteractionNotAllowed:
            // If the app is backgrounded, Security can refuse interaction without
            // implying the user denied access. Leave the cached state untouched.
            break
        #endif
        default:
            break
        }
    }

    private static func claudeKeychainAccessDeniedAt() -> Date? {
        UserDefaults.standard.object(forKey: claudeKeychainAccessDeniedAtDefaultsKey) as? Date
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

    // MARK: - Gemini

    private static func buildGeminiPayload(updatedAt: Int) -> [String: Any] {
        if let localSummary = loadJSONDictionary(fromCandidates: homePathCandidates([
            ".gemini/usage-summary.json",
            ".config/gemini/usage-summary.json"
        ])) {
            return buildGeminiPayloadFromLocalSummary(localSummary, updatedAt: updatedAt)
        }

        let hasAuth = loadGeminiOAuthToken() != nil
        return [
            "available": hasAuth,
            "remainingPercent": NSNull(),
            "source": hasAuth ? "auth-token" : "unavailable",
            "updatedAt": updatedAt
        ]
    }

    private static func buildGeminiPayloadFromLocalSummary(_ data: [String: Any], updatedAt: Int) -> [String: Any] {
        let remainingPercent = geminiRemainingPercent(from: data)
        var payload: [String: Any] = [
            "available": true,
            "source": "local-summary",
            "updatedAt": data["updatedAt"] ?? updatedAt
        ]
        payload["remainingPercent"] = remainingPercent ?? NSNull()
        return payload
    }

    private static func geminiRemainingPercent(from payload: [String: Any]) -> Double? {
        let candidates: [Any?] = [
            payload["remainingPercent"],
            payload["remaining_percent"],
            payload["percentRemaining"],
            payload["remaining"],
            payload["availablePercent"]
        ]
        for candidate in candidates {
            if let value = asDoubleOrNil(candidate) {
                return max(0, min(100, value))
            }
        }
        return nil
    }

    private static func loadGeminiOAuthToken() -> String? {
        for credPath in homePathCandidates([
            ".gemini/oauth_creds.json",
            ".gemini/credentials.json",
            ".config/gemini/oauth_creds.json",
            ".config/gemini/credentials.json"
        ]) {
            let url = URL(fileURLWithPath: credPath)
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if let token = object["access_token"] as? String, !token.isEmpty {
                return token
            }
            if let token = object["token"] as? String, !token.isEmpty {
                return token
            }
        }
        return nil
    }

    // MARK: - Shared

    private static func fetchJSON(
        url: URL,
        bearerToken: String,
        timeout: TimeInterval,
        extraHeaders: [String: String] = [:]
    ) -> [String: Any]? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("SuperIsland/1.0", forHTTPHeaderField: "User-Agent")
        for (header, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }

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

    private static func asDoubleOrNil(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String, let parsed = Double(value) { return parsed }
        return nil
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
