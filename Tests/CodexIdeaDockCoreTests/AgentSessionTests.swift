import XCTest
@testable import CodexIdeaDockCore

final class AgentSessionTests: XCTestCase {
    func testClaudeAdapterListsAndReads() throws {
        let adapter = ClaudeCodeAdapter()
        let sessions = try adapter.listSessions(limit: 5)
        try XCTSkipIf(sessions.isEmpty, "本机没有 Claude Code 会话记录")

        for s in sessions {
            print("• \(s.title.prefix(40))  |  \(s.projectPath ?? "-")  |  \(s.updatedAt)")
        }

        let first = sessions[0]
        let messages = try adapter.messages(in: first, limit: 6)
        XCTAssertFalse(messages.isEmpty, "会话里应能解析出消息")
        for m in messages.suffix(3) {
            print("  [\(m.role.rawValue)] \(m.text.prefix(60).replacingOccurrences(of: "\n", with: " "))")
        }
    }

    func testSendIsUnsupportedForNow() async throws {
        let adapter = ClaudeCodeAdapter()
        guard let session = try adapter.listSessions(limit: 1).first else {
            throw XCTSkip("无会话")
        }
        do {
            try await adapter.send("test", to: session)
            XCTFail("发送应抛 unsupported")
        } catch AgentAdapterError.unsupported {
            // 预期
        }
    }
}
