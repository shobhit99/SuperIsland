import Foundation

enum AIUsageProvider {
    static func snapshot() -> [String: Any] {
        let now = Int(Date().timeIntervalSince1970)

        let codex = loadJSONDictionary(fromCandidates: [
            "~/.codex/usage-summary.json",
            "~/.codex/usage/summary.json"
        ])

        let claude = loadJSONDictionary(fromCandidates: [
            "~/.claude/usage-summary.json",
            "~/.config/claude/usage-summary.json"
        ])

        return [
            "updatedAt": now,
            "codex": buildCodexPayload(from: codex, updatedAt: now),
            "claude": buildClaudePayload(from: claude, updatedAt: now)
        ]
    }

    private static func buildCodexPayload(from data: [String: Any]?, updatedAt: Int) -> [String: Any] {
        guard let data else {
            return [
                "available": false,
                "primary": NSNull(),
                "secondary": NSNull(),
                "planType": NSNull(),
                "hasCredits": false,
                "unlimited": false,
                "updatedAt": updatedAt
            ]
        }

        return [
            "available": true,
            "primary": data["primary"] ?? NSNull(),
            "secondary": data["secondary"] ?? NSNull(),
            "planType": data["planType"] ?? NSNull(),
            "hasCredits": data["hasCredits"] as? Bool ?? false,
            "unlimited": data["unlimited"] as? Bool ?? false,
            "updatedAt": data["updatedAt"] ?? updatedAt
        ]
    }

    private static func buildClaudePayload(from data: [String: Any]?, updatedAt: Int) -> [String: Any] {
        guard let data else {
            return [
                "available": false,
                "status": NSNull(),
                "statusLabel": NSNull(),
                "hoursTillReset": NSNull(),
                "resetAt": NSNull(),
                "model": NSNull(),
                "updatedAt": updatedAt,
                "unifiedRateLimitFallbackAvailable": false,
                "isBlocked": false
            ]
        }

        return [
            "available": true,
            "status": data["status"] ?? NSNull(),
            "statusLabel": data["statusLabel"] ?? NSNull(),
            "hoursTillReset": data["hoursTillReset"] ?? NSNull(),
            "resetAt": data["resetAt"] ?? NSNull(),
            "model": data["model"] ?? NSNull(),
            "updatedAt": data["updatedAt"] ?? updatedAt,
            "unifiedRateLimitFallbackAvailable": data["unifiedRateLimitFallbackAvailable"] as? Bool ?? false,
            "isBlocked": data["isBlocked"] as? Bool ?? false
        ]
    }

    private static func loadJSONDictionary(fromCandidates candidates: [String]) -> [String: Any]? {
        for candidate in candidates {
            let expanded = NSString(string: candidate).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
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
}
