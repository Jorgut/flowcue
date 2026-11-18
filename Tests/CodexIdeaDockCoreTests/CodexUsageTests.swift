import Foundation
import XCTest
@testable import CodexIdeaDockCore

final class CodexUsageTests: XCTestCase {
    func testCodexBucketWinsAndWeeklyCanBePrimary() throws {
        let data = Data(#"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":31,"windowDurationMins":10080,"resetsAt":1790000000},"secondary":null}}}}"#.utf8)
        let snapshot = try CodexUsageSnapshot.parse(data)
        XCTAssertEqual(snapshot.primary?.usedPercent, 31)
        XCTAssertEqual(snapshot.primary?.remainingPercent, 69)
        XCTAssertEqual(snapshot.primary?.windowDurationMins, 10080)
        XCTAssertNil(snapshot.secondary)
    }

    func testUnavailableAndInvalidAreNotZeroUsage() {
        for payload in [#"{"id":2,"result":{"rateLimits":{"primary":null,"secondary":null}}}"#,
                        #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":101}}}}"#,
                        #"{"id":2,"error":{"code":-1}}"#] {
            XCTAssertThrowsError(try CodexUsageSnapshot.parse(Data(payload.utf8)))
        }
    }

    func testInvalidWindowMetadataIsRejected() {
        for fields in ["\"windowDurationMins\":0", "\"windowDurationMins\":-1", "\"resetsAt\":1e308", "\"resetsAt\":-1"] {
            let payload = "{\"id\":2,\"result\":{\"rateLimits\":{\"primary\":{\"usedPercent\":12," + fields + "}}}}"
            XCTAssertThrowsError(try CodexUsageSnapshot.parse(Data(payload.utf8)))
        }
    }

    func testLegacyResponseAndUnrelatedNotifications() throws {
        let payload = "{\"method\":\"notice\"}\n" + #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":0,"windowDurationMins":300},"secondary":{"usedPercent":42,"windowDurationMins":10080}}}}"#
        let snapshot = try CodexUsageSnapshot.parse(Data(payload.utf8))
        XCTAssertEqual(snapshot.primary?.remainingPercent, 100)
        XCTAssertEqual(snapshot.secondary?.remainingPercent, 58)
    }
}
