import XCTest
@testable import CodexIdeaDockCore

final class AppUpdaterTests: XCTestCase {
    func testSHA256MatchesKnownDigest() {
        let digest = AppUpdater.sha256(Data("flowcue".utf8))
        XCTAssertEqual(digest, "d08f93a89d64a0fa1eed19cc1ed115a56bc67570d2a5889a86c05fc9b1b9e3b4")
    }

    func testCurrentVersionIsReadable() {
        XCTAssertFalse(AppUpdater.currentVersion.isEmpty)
    }
}
