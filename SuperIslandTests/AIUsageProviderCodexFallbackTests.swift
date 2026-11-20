import XCTest
@testable import SuperIsland

/// A single failed poll of the Codex usage endpoint used to replace the
/// numbers with "No data" (and a misleading "Auth token" source) until the
/// next successful refresh. Like the Claude fetcher, the last good payload
/// must be served marked as stale instead.
final class AIUsageProviderCodexFallbackTests: XCTestCase {

    private let fetchedAt = 1_700_000_000
    private let later = 1_700_000_900

    private func lastGood() -> [String: Any] {
        [
            "available": true,
            "primary": ["usedPercent": 12.0, "remainingPercent": 88.0, "windowMinutes": 300, "windowLabel": "5h"],
            "secondary": ["usedPercent": 40.0, "remainingPercent": 60.0, "windowMinutes": 10080, "windowLabel": "168h"],
            "planType": "pro",
            "hasCredits": false,
            "unlimited": false,
            "source": "oauth-api",
            "updatedAt": fetchedAt
        ]
    }

    func test_without_cached_data_an_authenticated_user_gets_the_auth_token_placeholder() {
        let payload = AIUsageProvider.codexFallbackPayload(lastGood: nil, hasAuth: true, updatedAt: later)

        XCTAssertEqual(payload["available"] as? Bool, true)
        XCTAssertEqual(payload["source"] as? String, "auth-token")
        XCTAssertTrue(payload["primary"] is NSNull)
        XCTAssertEqual(payload["updatedAt"] as? Int, later)
    }

    func test_without_cached_data_and_without_auth_codex_is_unavailable() {
        let payload = AIUsageProvider.codexFallbackPayload(lastGood: nil, hasAuth: false, updatedAt: later)

        XCTAssertEqual(payload["available"] as? Bool, false)
        XCTAssertEqual(payload["source"] as? String, "unavailable")
    }

    func test_cached_windows_are_served_again_marked_stale() {
        let payload = AIUsageProvider.codexFallbackPayload(lastGood: lastGood(), hasAuth: true, updatedAt: later)

        XCTAssertEqual(payload["available"] as? Bool, true)
        XCTAssertEqual(payload["stale"] as? Bool, true)
        XCTAssertEqual(payload["source"] as? String, "oauth-api-stale")
        XCTAssertEqual((payload["primary"] as? [String: Any])?["usedPercent"] as? Double, 12.0)
        XCTAssertEqual((payload["secondary"] as? [String: Any])?["usedPercent"] as? Double, 40.0)
        XCTAssertEqual(payload["planType"] as? String, "pro")
        // The timestamp keeps describing the moment the numbers were true.
        XCTAssertEqual(payload["updatedAt"] as? Int, fetchedAt)
    }

    func test_stale_payload_names_the_time_of_the_cached_fetch() {
        let payload = AIUsageProvider.codexFallbackPayload(lastGood: lastGood(), hasAuth: true, updatedAt: later)

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let expectedTime = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(fetchedAt)))

        XCTAssertEqual(payload["statusLabel"] as? String, "Codex usage API unreachable — data from \(expectedTime)")
    }

    func test_cached_data_is_served_even_when_the_auth_file_vanished() {
        // Codex signed out between polls: keep showing what we know, the
        // stale label already says the numbers are old.
        let payload = AIUsageProvider.codexFallbackPayload(lastGood: lastGood(), hasAuth: false, updatedAt: later)

        XCTAssertEqual(payload["available"] as? Bool, true)
        XCTAssertEqual(payload["stale"] as? Bool, true)
    }
}
