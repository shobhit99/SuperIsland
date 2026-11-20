import Foundation
#if os(macOS)
import Security
import LocalAuthentication
#endif

enum AIUsageProvider {
    private static let cacheTTL: TimeInterval = 300
    private static let claudeKeychainAccessStateDefaultsKey = "aiUsage.claude.keychainAccessState"
    private static let claudeKeychainAccessDeniedAtDefaultsKey = "aiUsage.claude.keychainAccessDeniedAt"
    private static let claudeKeychainPromptedDefaultsKey = "aiUsage.claude.keychainPrompted"
    private static let claudeKeychainPromptedAtDefaultsKey = "aiUsage.claude.keychainPromptedAt"
    private static let claudeKeychainPromptCooldown: TimeInterval = 24 * 60 * 60
    /// Opt-in (off by default): send Claude Code's User-Agent instead of this
    /// app's own. See claudeUsageUserAgent().
    private static let claudeCodeUserAgentDefaultsKey = "aiUsage.claude.useClaudeCodeUserAgent"
    private static var cachedSnapshot: [String: Any]?
    private static var cachedAt: Date?
    private static let cacheLock = NSLock()
    private static var isRefreshing = false

    // Process-lifetime cache for the Claude OAuth access token read from the
    // login keychain. Without this, every 5-minute snapshot refresh hits
    // SecItemCopyMatching and — for apps not on the keychain item's ACL —
    // macOS prompts for the login password on every read.
    private static let claudeTokenLock = NSLock()
    private static var cachedClaudeKeychainToken: ClaudeUsageFetcher.Token?

    /// The usage endpoint puts unknown agents in a much stricter rate-limit
    /// bucket than Claude Code's own, so identifying honestly costs data:
    /// expect frequent 429s and mostly cached numbers. Claiming to be Claude
    /// Code buys accuracy, but it is the user's OAuth account that carries
    /// the abuse-detection and terms risk, and it breaks the moment the
    /// endpoint tightens the check — so it is never the default. Users who
    /// accept that trade opt in explicitly:
    ///
    ///     defaults write <bundle-id> aiUsage.claude.useClaudeCodeUserAgent -bool YES
    static func claudeUsageUserAgent() -> String {
        if UserDefaults.standard.bool(forKey: claudeCodeUserAgentDefaultsKey) {
            return ClaudeCodeVersionDetector.userAgent()
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "SuperIsland/\(version)"
    }

    static let claudeFetcher = ClaudeUsageFetcher(
        userAgent: { claudeUsageUserAgent() },
        loadToken: { loadClaudeToken(ignoringCache: $0) },
        invalidateCachedToken: { invalidateCachedClaudeToken() },
        httpFetch: { performHTTPJSONRequest($0, timeout: 3.0) },
        buildPayload: { claudeOAuthResponsePayload(from: $0, updatedAt: $1) }
    )

    enum ClaudeKeychainAccessState: String {
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
            "claude": ["available": false, "source": "loading"] as [String: Any]
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
                "claude": buildClaudePayload(updatedAt: now)
            ]

            cacheLock.lock()
            cachedAt = nowDate
            cachedSnapshot = payload
            isRefreshing = false
            cacheLock.unlock()
        }
    }

    // MARK: - Codex

    private static let codexLock = NSLock()
    private static var codexLastGoodPayload: [String: Any]?

    private static func buildCodexPayload(updatedAt: Int) -> [String: Any] {
        if let localSummary = loadJSONDictionary(fromCandidates: homePathCandidates([
            ".codex/usage-summary.json",
            ".codex/usage/summary.json"
        ])) {
            return buildCodexPayloadFromLocalSummary(localSummary, updatedAt: updatedAt)
        }

        if let oauthPayload = loadCodexPayloadFromOAuthAPI(updatedAt: updatedAt) {
            codexLock.lock()
            codexLastGoodPayload = oauthPayload
            codexLock.unlock()
            return oauthPayload
        }

        codexLock.lock()
        let lastGood = codexLastGoodPayload
        codexLock.unlock()
        return codexFallbackPayload(lastGood: lastGood, hasAuth: loadCodexAccessToken() != nil, updatedAt: updatedAt)
    }

    /// What to show when the usage endpoint did not answer: the previous
    /// successful payload marked stale (a single failed poll — offline,
    /// timeout, 5xx — must not wipe the numbers), or, without one, a
    /// placeholder that still marks Codex as available when auth exists so
    /// the UI does not fall back to N/A.
    static func codexFallbackPayload(lastGood: [String: Any]?, hasAuth: Bool, updatedAt: Int) -> [String: Any] {
        if var payload = lastGood {
            payload["available"] = true
            payload["stale"] = true
            payload["source"] = "oauth-api-stale"
            if let fetchedAt = payload["updatedAt"] as? Int {
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm"
                let time = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(fetchedAt)))
                payload["statusLabel"] = "Codex usage API unreachable — data from \(time)"
            } else {
                payload["statusLabel"] = "Codex usage API unreachable — showing cached data"
            }
            return payload
        }

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

        // Surface the last OAuth failure so the UI can distinguish
        // rate-limited / auth-error / offline from a plain "no data".
        let failure = claudeFetcher.lastFailure
        return [
            "available": false,
            "status": NSNull(),
            "statusLabel": failure?.label ?? NSNull(),
            "remainingPercent": NSNull(),
            "weeklyRemainingPercent": NSNull(),
            "currentSessionRemainingPercent": NSNull(),
            "hoursTillReset": NSNull(),
            "resetAt": NSNull(),
            "model": NSNull(),
            "updatedAt": updatedAt,
            "unifiedRateLimitFallbackAvailable": false,
            "isBlocked": false,
            "source": failure?.rawValue ?? "unavailable"
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
        claudeFetcher.payload(updatedAt: updatedAt)
    }

    /// Maps a successful OAuth usage response to the module payload.
    /// Returns nil when the response lacks every usage window. `five_hour`
    /// is null while no 5-hour window is open, so the weekly windows alone
    /// are enough.
    static func claudeOAuthResponsePayload(from response: [String: Any], updatedAt: Int) -> [String: Any]? {
        let sessionRemainingPercent = claudeCurrentSessionRemainingPercent(from: response)
        let weeklyRemainingPercent = claudeWeeklyRemainingPercent(from: response)
        guard let overallRemainingPercent = [sessionRemainingPercent, weeklyRemainingPercent].compactMap({ $0 }).min() else {
            return nil
        }
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
        payload["currentSessionRemainingPercent"] = sessionRemainingPercent ?? NSNull()
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

    /// Loads the Claude OAuth token together with its expiry so callers can
    /// avoid sending requests with a token Claude Code has already rotated.
    /// `ignoringCache` forces a fresh keychain read (used after auth errors)
    /// and never prompts the user.
    static func loadClaudeToken(ignoringCache: Bool) -> ClaudeUsageFetcher.Token? {
        let environment = ProcessInfo.processInfo.environment
        let envKeys = [
            "CLAUDE_CODE_OAUTH_ACCESS_TOKEN",
            "CLAUDE_OAUTH_ACCESS_TOKEN",
            "ANTHROPIC_OAUTH_ACCESS_TOKEN"
        ]
        for key in envKeys {
            if let token = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !token.isEmpty {
                return ClaudeUsageFetcher.Token(value: token, expiresAt: nil)
            }
        }

        if let token = loadClaudeTokenFromCredentialsFile() {
            return token
        }

        #if os(macOS)
        if !ignoringCache {
            claudeTokenLock.lock()
            let cachedKeychain = cachedClaudeKeychainToken
            claudeTokenLock.unlock()
            if let cachedKeychain {
                return cachedKeychain
            }
        }

        if let token = loadClaudeTokenFromKeychain(allowUserInteraction: false) {
            claudeTokenLock.lock()
            cachedClaudeKeychainToken = token
            claudeTokenLock.unlock()
            return token
        }

        guard !ignoringCache, shouldPromptForClaudeKeychainAccess() else {
            return nil
        }

        setClaudeKeychainPrompted()
        if let token = loadClaudeTokenFromKeychain(allowUserInteraction: true) {
            claudeTokenLock.lock()
            cachedClaudeKeychainToken = token
            claudeTokenLock.unlock()
            return token
        }
        #endif

        return nil
    }

    static func invalidateCachedClaudeToken() {
        claudeTokenLock.lock()
        cachedClaudeKeychainToken = nil
        claudeTokenLock.unlock()
    }

    private static func loadClaudeTokenFromCredentialsFile() -> ClaudeUsageFetcher.Token? {
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
                  let token = claudeToken(fromJSONObject: object) else {
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

    static func claudeToken(fromJSONObject object: Any) -> ClaudeUsageFetcher.Token? {
        // The keychain item keeps several OAuth blocks side by side
        // (claudeAiOauth, designOauth, mcpOAuth[...]). Only claudeAiOauth is
        // the Claude Code sign-in, so when that block exists it alone
        // decides — an empty one means signed out even if another product's
        // token is present. Other layouts (a flat credentials file) keep the
        // tolerant deep search.
        if let dictionary = object as? [String: Any], let claudeAiOauth = dictionary["claudeAiOauth"] {
            guard let block = claudeAiOauth as? [String: Any] else {
                return nil
            }
            return claudeToken(fromOAuthBlock: block)
        }
        return claudeToken(fromOAuthBlock: object)
    }

    private static func claudeToken(fromOAuthBlock object: Any) -> ClaudeUsageFetcher.Token? {
        guard let token = claudeAccessToken(fromJSONObject: object) else {
            return nil
        }

        // Claude Code stores expiresAt as milliseconds since the epoch;
        // accept plain seconds too in case the format ever changes.
        let expiresAt = findNumberValue(
            in: object,
            keys: ["expiresAt", "expires_at"],
            depth: 0,
            maxDepth: 8
        ).map { raw in
            Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
        }

        return ClaudeUsageFetcher.Token(value: token, expiresAt: expiresAt)
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

    private static func findNumberValue(
        in object: Any,
        keys: Set<String>,
        depth: Int,
        maxDepth: Int
    ) -> Double? {
        if depth > maxDepth {
            return nil
        }

        if let dictionary = object as? [String: Any] {
            for key in keys {
                if let value = asDoubleOrNil(dictionary[key]) {
                    return value
                }
            }

            for value in dictionary.values {
                if let nested = findNumberValue(
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
                if let nested = findNumberValue(
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
    private static func loadClaudeTokenFromKeychain(allowUserInteraction: Bool) -> ClaudeUsageFetcher.Token? {
        let context = LAContext()
        context.interactionNotAllowed = !allowUserInteraction
        context.localizedReason = "Access Claude Code credentials for AI usage status."

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        query[kSecUseAuthenticationContext as String] = context
        if !allowUserInteraction {
            // LAContext.interactionNotAllowed suppresses LocalAuthentication
            // UI, but NOT the classic securityd ACL password dialog — without
            // this flag every background read of an item we lost the ACL
            // grant for (Claude Code occasionally recreates the item, which
            // drops the "Always Allow" entry) pops the password prompt.
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }

        // kSecUseAuthenticationUI only governs data-protection keychain items.
        // "Claude Code-credentials" lives in the legacy file-based login
        // keychain, whose ACL password dialog ignores it — the deprecated
        // process-global switch is the only way to keep a background read
        // from prompting. Restore it immediately so an interactive attempt
        // (at most one per day) can still show the dialog.
        if !allowUserInteraction {
            SecKeychainSetUserInteractionAllowed(false)
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if !allowUserInteraction {
            SecKeychainSetUserInteractionAllowed(true)
        }
        updateClaudeKeychainAccessState(for: status, interactive: allowUserInteraction)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        if let object = try? JSONSerialization.jsonObject(with: data),
           let token = claudeToken(fromJSONObject: object) {
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
           let token = claudeToken(fromJSONObject: object) {
            return token
        }

        return nil
    }
    #endif

    private static func shouldPromptForClaudeKeychainAccess() -> Bool {
        #if os(macOS)
        // Someone who refused access is never asked again by the app.
        guard claudeKeychainAccessState() != .denied else {
            return false
        }
        if let promptedAt = UserDefaults.standard.object(forKey: claudeKeychainPromptedAtDefaultsKey) as? Date {
            // Not a denial, so this is the "ACL grant lost" case: Claude Code
            // occasionally recreates the keychain item, which drops the
            // "Always Allow" entry. One retry per day recovers from that
            // without turning into a daily nag.
            return Date().timeIntervalSince(promptedAt) > claudeKeychainPromptCooldown
        }
        if UserDefaults.standard.bool(forKey: claudeKeychainPromptedDefaultsKey) {
            // Upgrading from the legacy once-forever flag: record when we
            // adopted it instead of prompting straight away, so an existing
            // user is not re-prompted just because the app updated.
            UserDefaults.standard.set(Date(), forKey: claudeKeychainPromptedAtDefaultsKey)
            UserDefaults.standard.removeObject(forKey: claudeKeychainPromptedDefaultsKey)
            return false
        }
        return true
        #else
        return false
        #endif
    }

    private static func setClaudeKeychainPrompted() {
        UserDefaults.standard.set(Date(), forKey: claudeKeychainPromptedAtDefaultsKey)
        UserDefaults.standard.removeObject(forKey: claudeKeychainPromptedDefaultsKey)
    }

    private static func claudeKeychainAccessState() -> ClaudeKeychainAccessState {
        guard let rawValue = UserDefaults.standard.string(forKey: claudeKeychainAccessStateDefaultsKey),
              let state = ClaudeKeychainAccessState(rawValue: rawValue) else {
            return .unknown
        }

        let defaults = UserDefaults.standard
        let promptRecorded = defaults.object(forKey: claudeKeychainPromptedAtDefaultsKey) != nil
            || defaults.bool(forKey: claudeKeychainPromptedDefaultsKey)
        return effectiveClaudeKeychainAccessState(stored: state, promptRecorded: promptRecorded)
    }

    /// An explicit denial is sticky. It is cleared only by a successful read
    /// (see updateClaudeKeychainAccessState), which happens once the user
    /// grants access from the macOS dialog or Keychain Access — never by
    /// elapsed time, or the app would nag a user who said no.
    ///
    /// A denial can only come from a dialog the user saw, so a stored
    /// `.denied` without any prompt on record (earlier builds wrote it from
    /// background reads) is not a user decision and is ignored.
    static func effectiveClaudeKeychainAccessState(
        stored: ClaudeKeychainAccessState,
        promptRecorded: Bool
    ) -> ClaudeKeychainAccessState {
        if stored == .denied && !promptRecorded {
            return .unknown
        }
        return stored
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

    private static func updateClaudeKeychainAccessState(for status: OSStatus, interactive: Bool) {
        if status != errSecSuccess {
            NSLog("SuperIsland AIUsage: claude keychain read failed status=%d interactive=%d", status, interactive ? 1 : 0)
        }
        if let state = claudeKeychainAccessState(after: status, interactive: interactive) {
            setClaudeKeychainAccessState(state)
        }
    }

    /// Maps a SecItemCopyMatching result to the access state it proves, or
    /// nil when it proves nothing about the user's intent.
    ///
    /// Only a dialog the user actually saw can be a refusal. A background
    /// read with interaction disabled fails with errSecAuthFailed as well
    /// (observed on macOS 26/27 when the item's ACL or partition list no
    /// longer covers the app, e.g. after Claude Code rewrote the item), and
    /// treating that as a denial would silence the dialog forever.
    static func claudeKeychainAccessState(after status: OSStatus, interactive: Bool) -> ClaudeKeychainAccessState? {
        switch status {
        case errSecSuccess:
            return .allowed
        #if os(macOS)
        case errSecAuthFailed, errSecUserCanceled:
            return interactive ? .denied : nil
        #endif
        default:
            return nil
        }
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

    /// Synchronous HTTP request that preserves status code, headers, and
    /// transport errors. Used by the Claude fetcher; Codex keeps the simpler
    /// `fetchJSON` below.
    static func performHTTPJSONRequest(_ request: URLRequest, timeout: TimeInterval) -> HTTPJSONResult {
        let semaphore = DispatchSemaphore(value: 0)
        var captured: (data: Data?, response: URLResponse?, error: Error?) = (nil, nil, nil)

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            captured = (data, response, error)
            semaphore.signal()
        }

        task.resume()
        if semaphore.wait(timeout: .now() + timeout + 0.3) == .timedOut {
            task.cancel()
            return HTTPJSONResult(statusCode: nil, headers: [:], json: nil, error: URLError(.timedOut))
        }

        let http = captured.response as? HTTPURLResponse
        let json = captured.data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return HTTPJSONResult(
            statusCode: http?.statusCode,
            headers: http?.allHeaderFields ?? [:],
            json: json,
            error: captured.error
        )
    }

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

            let statusCode = (response as? HTTPURLResponse)?.statusCode
            guard error == nil,
                  let statusCode,
                  (200..<300).contains(statusCode),
                  let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                NSLog(
                    "SuperIsland AIUsage: request to %@ failed status=%@ error=%@",
                    url.host ?? url.absoluteString,
                    statusCode.map(String.init) ?? "none",
                    error.map { "\($0)" } ?? (data == nil ? "no body" : "unexpected body")
                )
                return
            }
            parsed = object
        }

        task.resume()
        if semaphore.wait(timeout: .now() + timeout + 0.3) == .timedOut {
            NSLog("SuperIsland AIUsage: request to %@ timed out after %.1fs", url.host ?? url.absoluteString, timeout)
        }
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
