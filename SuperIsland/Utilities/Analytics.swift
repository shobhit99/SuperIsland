import Foundation
import Aptabase

/// Privacy-friendly usage analytics via Aptabase.
/// Counts unique users (anonymous) and lets us see which features are used.
enum Analytics {
    /// Aptabase App Key. Tied to the SuperIsland project on aptabase.com.
    private static let appKey = "A-US-9480990542"

    /// Call once at app launch — safe to call multiple times (Aptabase guards).
    static func start() {
        Aptabase.shared.initialize(appKey: appKey)
    }

    /// Fire a named event with optional key/value properties.
    /// Safe to call from anywhere; no-op until `start()` has run.
    static func track(_ event: String, properties: [String: Any]? = nil) {
        if let properties {
            Aptabase.shared.trackEvent(event, with: properties)
        } else {
            Aptabase.shared.trackEvent(event)
        }
    }
}
