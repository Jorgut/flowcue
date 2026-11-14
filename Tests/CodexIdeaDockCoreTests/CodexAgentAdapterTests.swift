import XCTest
@testable import CodexIdeaDockCore

final class CodexAgentAdapterTests: XCTestCase {
    func testListAndReadCodexThreads() throws {
        let adapter = CodexAgentAdapter()
        let sessions: [AgentSession]
        do {
            sessions = try adapter.listSessions(limit: 3)
        } catch {
            throw XCTSkip("codex app-server 不可用：\(error)")
        }
        try XCTSkipIf(sessions.isEmpty, "没有 Codex 会话")

        for s in sessions {
            print("• \(s.title.prefix(50))  |  \(s.projectPath ?? "-")  |  \(s.updatedAt)")
        }

        let messages = try adapter.messages(in: sessions[0], limit: 10)
        XCTAssertFalse(messages.isEmpty)
        for m in messages.suffix(3) {
            print("  [\(m.role.rawValue)] \(m.text.prefix(60).replacingOccurrences(of: "\n", with: " "))")
        }
    }
}
