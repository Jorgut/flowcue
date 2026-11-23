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

    /// DSH 的对话内容从本机会话日志读；不存在的会话应报 notFound，
    /// 而不是像以前那样一律 unsupported。
    func testDSHMessagesReadFromSessionLog() async throws {
        let adapter = DSHAgentAdapter()
        let session = AgentSession(id: "does-not-exist", agentID: "dsh", title: "t", updatedAt: Date(),
                                   projectPath: nil, messageCount: nil, locator: "does-not-exist")
        do {
            let messages = try await adapter.messages(in: session, limit: 5)
            // 若本机恰好有同名会话，至少应能读出消息
            XCTAssertFalse(messages.isEmpty)
        } catch AgentAdapterError.notFound {
            // 预期：会话不存在
        } catch AgentAdapterError.unsupported {
            XCTFail("DSH 对话不应再是 unsupported")
        }
    }
}
