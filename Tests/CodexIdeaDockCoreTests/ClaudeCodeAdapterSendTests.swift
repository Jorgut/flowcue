import XCTest
@testable import CodexIdeaDockCore

final class ClaudeCodeAdapterSendTests: XCTestCase {
    /// `claude --resume` 要的是 session id，不是 JSONL 文件路径。
    /// 以前传 session.locator（/Users/.../<id>.jsonl）会被 CLI 当成未知会话。
    func testResumeUsesSessionIDNotJSONLPath() {
        let args = ClaudeCodeAdapter.resumeArguments(sessionID: "59f1472c-d1ab-40a4-8c3c-6de85791ea21", text: "hi")
        XCTAssertEqual(args, ["-p", "--resume", "59f1472c-d1ab-40a4-8c3c-6de85791ea21", "hi"])
        XCTAssertFalse(args.contains { $0.hasSuffix(".jsonl") })
    }
}
