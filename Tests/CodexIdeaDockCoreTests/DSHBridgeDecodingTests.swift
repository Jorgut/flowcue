import XCTest
@testable import CodexIdeaDockCore

final class DSHBridgeDecodingTests: XCTestCase {
    func testLocalizedDisplayReasonObjectDecodes() throws {
        let json = """
        [{"id":"a1","sessionId":"s1","toolName":"bash","callId":"c1",
        "reason":"Auto review denied tool bash",
        "displayReason":{"en":"Auto review denied this call: test","zh":"Auto review 拒绝了此调用：测试"},
        "createdAt":"2026-11-19T06:05:27.758Z"}]
        """
        let pending = try JSONDecoder().decode([DSHRemoteApproval].self, from: Data(json.utf8))
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].title, "Auto review 拒绝了此调用：测试")
    }

    func testPlainStringDisplayReasonStillDecodes() throws {
        let json = """
        [{"id":"a2","reason":"plain","displayReason":"plain display"}]
        """
        let pending = try JSONDecoder().decode([DSHRemoteApproval].self, from: Data(json.utf8))
        XCTAssertEqual(pending[0].displayReason, "plain display")
    }
}
