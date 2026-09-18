import XCTest
import JavaScriptCore
@testable import SuperIsland

final class ExtensionViewNodeTests: XCTestCase {
    func testCircularProgressParsesExplicitSize() throws {
        let context = try XCTUnwrap(JSContext())
        let value = context.evaluateScript(
            "({ type: 'circular-progress', value: 0.5, total: 1, lineWidth: 3, size: 18, color: 'green' })"
        )

        XCTAssertEqual(
            ViewNode.from(value),
            .circularProgress(
                value: 0.5,
                total: 1,
                lineWidth: 3,
                size: 18,
                color: .named("green")
            )
        )
    }

    func testCircularProgressLeavesSizeUnsetWhenOmitted() throws {
        let context = try XCTUnwrap(JSContext())
        let value = context.evaluateScript(
            "({ type: 'circular-progress', value: 0.5, total: 1, lineWidth: 3, color: 'green' })"
        )

        XCTAssertEqual(
            ViewNode.from(value),
            .circularProgress(
                value: 0.5,
                total: 1,
                lineWidth: 3,
                size: nil,
                color: .named("green")
            )
        )
    }
}
