import XCTest
@testable import SuperIsland

/// Picking the Claude Code token out of the "Claude Code-credentials"
/// keychain item. The item holds several OAuth blocks side by side
/// (`claudeAiOauth`, `designOauth`, `mcpOAuth`), so "first access token
/// found anywhere" is not a sign-in check.
final class AIUsageProviderClaudeTokenTests: XCTestCase {

    private let claudeToken = "claude-code-token-value"
    private let designToken = "claude-design-token-value"

    func test_claudeAiOauth_token_wins_over_other_oauth_blocks() throws {
        let object: [String: Any] = [
            "designOauth": ["accessToken": designToken, "expiresAt": 1_900_000_000_000],
            "claudeAiOauth": ["accessToken": claudeToken, "expiresAt": 1_800_000_000_000],
            "mcpOAuth": ["some-server": ["accessToken": ""]]
        ]

        let token = try XCTUnwrap(AIUsageProvider.claudeToken(fromJSONObject: object))
        XCTAssertEqual(token.value, claudeToken)
        XCTAssertEqual(token.expiresAt, Date(timeIntervalSince1970: 1_800_000_000))
    }

    func test_empty_claudeAiOauth_means_signed_out_even_if_another_block_has_a_token() {
        // Exactly what the item looks like after `claude /logout` while the
        // Claude Design sign-in is still there.
        let object: [String: Any] = [
            "claudeAiOauth": ["accessToken": "", "refreshToken": "", "expiresAt": 0],
            "designOauth": ["accessToken": designToken, "expiresAt": 1_900_000_000_000]
        ]

        XCTAssertNil(AIUsageProvider.claudeToken(fromJSONObject: object))
    }

    func test_flat_credentials_layout_still_parses() throws {
        let object: [String: Any] = ["access_token": claudeToken, "expires_at": 1_800_000_000]

        let token = try XCTUnwrap(AIUsageProvider.claudeToken(fromJSONObject: object))
        XCTAssertEqual(token.value, claudeToken)
        XCTAssertEqual(token.expiresAt, Date(timeIntervalSince1970: 1_800_000_000))
    }
}

/// The usage endpoint reports `five_hour: null` while no 5-hour window is
/// open; the weekly windows are still there. That is usage data, not an
/// unexpected response.
final class AIUsageProviderOAuthPayloadTests: XCTestCase {

    func test_response_without_five_hour_window_builds_from_the_weekly_window() throws {
        let response: [String: Any] = [
            "five_hour": NSNull(),
            "seven_day": ["utilization": 15.0, "resets_at": "2026-11-21T08:00:00+00:00"]
        ]

        let payload = try XCTUnwrap(AIUsageProvider.claudeOAuthResponsePayload(from: response, updatedAt: 1))
        XCTAssertEqual(payload["available"] as? Bool, true)
        XCTAssertEqual(payload["remainingPercent"] as? Double, 85.0)
        XCTAssertEqual(payload["weeklyRemainingPercent"] as? Double, 85.0)
        XCTAssertTrue(payload["currentSessionRemainingPercent"] is NSNull,
                      "no open session window must not be reported as a number")
        XCTAssertEqual(payload["status"] as? String, "allowed")
    }

    func test_response_without_any_usage_window_is_still_rejected() {
        XCTAssertNil(AIUsageProvider.claudeOAuthResponsePayload(from: ["five_hour": NSNull(), "ok": true], updatedAt: 1))
    }

    func test_payload_from_a_weekly_only_response_is_persistable_json() throws {
        let response: [String: Any] = [
            "five_hour": NSNull(),
            "seven_day": ["utilization": 15.0, "resets_at": "2026-11-21T08:00:00+00:00"]
        ]
        let payload = try XCTUnwrap(AIUsageProvider.claudeOAuthResponsePayload(from: response, updatedAt: 1))
        XCTAssertTrue(JSONSerialization.isValidJSONObject(payload))
    }
}
