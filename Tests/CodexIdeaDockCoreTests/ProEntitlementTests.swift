import XCTest
@testable import CodexIdeaDockCore

final class ProEntitlementTests: XCTestCase {
    override func tearDown() {
        ProEntitlement.publish(expiry: nil)
    }

    func testNoExpiryMeansNotPro() {
        ProEntitlement.publish(expiry: nil)
        XCTAssertFalse(ProEntitlement.isPro())
    }

    func testFutureExpiryIsPro() {
        ProEntitlement.publish(expiry: Date().addingTimeInterval(86_400 * 30))
        XCTAssertTrue(ProEntitlement.isPro())
    }

    func testGracePeriodKeepsProForAWeek() {
        let expired = Date().addingTimeInterval(-86_400 * 3)
        ProEntitlement.publish(expiry: expired)
        XCTAssertTrue(ProEntitlement.isPro(), "过期 3 天仍在 7 天宽限内")

        ProEntitlement.publish(expiry: Date().addingTimeInterval(-86_400 * 10))
        XCTAssertFalse(ProEntitlement.isPro(), "过期 10 天应失效")
    }
}
