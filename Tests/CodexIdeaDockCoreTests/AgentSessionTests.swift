import XCTest
@testable import CodexIdeaDockCore

final class AgentSessionTests: XCTestCase {
    func testClaudeAdapterListsAndReads() async throws {
        let adapter = ClaudeCodeAdapter()
        guard let sessions = try? await adapter.listSessions(limit: 5) else {
            throw XCTSkip("本机没有 Claude Code 数据（CI 环境正常跳过）")
        }
        try XCTSkipIf(sessions.isEmpty, "本机没有 Claude Code 会话记录")

        for s in sessions {
            print("• \(s.title.prefix(40))  |  \(s.projectPath ?? "-")  |  \(s.updatedAt)")
        }

        let first = sessions[0]
        let messages = try await adapter.messages(in: first, limit: 6)
        XCTAssertFalse(messages.isEmpty, "会话里应能解析出消息")
        for m in messages.suffix(3) {
            print("  [\(m.role.rawValue)] \(m.text.prefix(60).replacingOccurrences(of: "\n", with: " "))")
        }
    }

    func testDSHMessagesStayUnsupported() async throws {
        let adapter = DSHAgentAdapter()
        let session = AgentSession(id: "s", agentID: "dsh", title: "t", updatedAt: Date(),
                                   projectPath: nil, messageCount: nil, locator: "s")
        do {
            _ = try await adapter.messages(in: session, limit: 5)
            XCTFail("DSH 对话应抛 unsupported")
        } catch AgentAdapterError.unsupported {
            // 预期：桥只提供待审与发消息
        }
    }
}
