import XCTest
import Security
@testable import SuperIsland

/// The keychain access state decides whether the app may ever show the
/// macOS "allow access" dialog again. A wrong `.denied` is permanent for
/// the user (no dialog, no data, no hint), so the classification of
/// SecItemCopyMatching results must be exact.
final class AIUsageProviderKeychainStateTests: XCTestCase {

    // MARK: - Classifying a read result

    func test_background_read_failing_with_authFailed_is_not_a_denial() {
        // Observed on macOS 26/27: a read with user interaction disabled
        // against an item whose ACL/partition list no longer covers us
        // returns errSecAuthFailed, not errSecInteractionNotAllowed. The
        // user saw no dialog, so nothing was refused.
        XCTAssertNil(
            AIUsageProvider.claudeKeychainAccessState(after: errSecAuthFailed, interactive: false)
        )
    }

    func test_background_read_failing_with_userCanceled_is_not_a_denial() {
        XCTAssertNil(
            AIUsageProvider.claudeKeychainAccessState(after: errSecUserCanceled, interactive: false)
        )
    }

    func test_interactive_read_cancelled_by_user_is_a_denial() {
        XCTAssertEqual(
            AIUsageProvider.claudeKeychainAccessState(after: errSecUserCanceled, interactive: true),
            .denied
        )
    }

    func test_interactive_read_failing_with_authFailed_is_a_denial() {
        XCTAssertEqual(
            AIUsageProvider.claudeKeychainAccessState(after: errSecAuthFailed, interactive: true),
            .denied
        )
    }

    func test_successful_read_is_allowed_regardless_of_interactivity() {
        XCTAssertEqual(
            AIUsageProvider.claudeKeychainAccessState(after: errSecSuccess, interactive: false),
            .allowed
        )
        XCTAssertEqual(
            AIUsageProvider.claudeKeychainAccessState(after: errSecSuccess, interactive: true),
            .allowed
        )
    }

    func test_missing_item_leaves_the_state_untouched() {
        XCTAssertNil(
            AIUsageProvider.claudeKeychainAccessState(after: errSecItemNotFound, interactive: true)
        )
    }

    // MARK: - Trusting a stored denial

    func test_denial_recorded_without_any_prompt_is_ignored() {
        // Earlier builds stored `.denied` from background reads; such a
        // record cannot come from a user decision because no dialog was
        // ever shown, so it must not block the one-per-day re-prompt.
        XCTAssertEqual(
            AIUsageProvider.effectiveClaudeKeychainAccessState(stored: .denied, promptRecorded: false),
            .unknown
        )
    }

    func test_denial_recorded_after_a_prompt_is_honored() {
        XCTAssertEqual(
            AIUsageProvider.effectiveClaudeKeychainAccessState(stored: .denied, promptRecorded: true),
            .denied
        )
    }

    func test_allowed_state_does_not_need_a_prompt_record() {
        XCTAssertEqual(
            AIUsageProvider.effectiveClaudeKeychainAccessState(stored: .allowed, promptRecorded: false),
            .allowed
        )
    }
}
