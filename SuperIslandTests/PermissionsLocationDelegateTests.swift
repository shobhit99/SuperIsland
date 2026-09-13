import CoreLocation
import XCTest
@testable import SuperIsland

final class PermissionsLocationDelegateTests: XCTestCase {

    // Regression test for the CoreLocation assertion
    // "Delegate must respond to locationManager:didUpdateLocations:".
    //
    // PermissionsManager's helper delegate only tracked authorization changes,
    // but a code path called requestLocation() on its CLLocationManager. Core
    // Location requires the delegate to implement didUpdateLocations (and
    // expects didFailWithError) before any location request; without them it
    // raised the assertion above and location delivery broke for the whole
    // process, leaving the Weather module empty. The delegate must therefore
    // always respond to both selectors.

    func testDelegateRespondsToDidUpdateLocations() {
        let delegate = PermissionsLocationDelegate()
        XCTAssertTrue(
            delegate.responds(to: #selector(CLLocationManagerDelegate.locationManager(_:didUpdateLocations:)))
        )
    }

    func testDelegateRespondsToDidFailWithError() {
        let delegate = PermissionsLocationDelegate()
        XCTAssertTrue(
            delegate.responds(to: #selector(CLLocationManagerDelegate.locationManager(_:didFailWithError:)))
        )
    }

    func testDelegateRespondsToAuthorizationChange() {
        let delegate = PermissionsLocationDelegate()
        XCTAssertTrue(
            delegate.responds(to: #selector(CLLocationManagerDelegate.locationManagerDidChangeAuthorization(_:)))
        )
    }

    func testAuthorizationCallbackForwardsStatus() {
        let delegate = PermissionsLocationDelegate()
        var received: CLAuthorizationStatus?
        delegate.onAuthorizationChange = { received = $0 }

        let manager = CLLocationManager()
        delegate.locationManagerDidChangeAuthorization(manager)

        XCTAssertEqual(received, manager.authorizationStatus)
    }
}
