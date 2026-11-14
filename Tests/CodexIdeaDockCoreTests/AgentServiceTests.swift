import XCTest
@testable import CodexIdeaDockCore

final class AgentServiceTests: XCTestCase {
    func testDefaultServiceCoversThreeAgents() {
        let service = AgentService.default
        XCTAssertEqual(service.supportedAgentIDs, ["claude", "codex", "dsh"])
    }

    func testUnknownAgentIsUnsupported() async {
        let service = AgentService.default
        do {
            _ = try await service.sessions(for: "nope")
            XCTFail("未知 agent 应抛错")
        } catch AgentAdapterError.unsupported {
            // 预期
        } catch {
            XCTFail("期望 unsupported，实际 \(error)")
        }
    }

    func testClaudeSessionsThroughService() async throws {
        let service = AgentService.default
        let sessions = try await service.sessions(for: "claude", limit: 3)
        try XCTSkipIf(sessions.isEmpty, "本机没有 Claude 会话")
        let messages = try await service.messages(sessions[0], limit: 5)
        XCTAssertFalse(messages.isEmpty)
        print("• service/claude: \(sessions.count) 会话，首条 \(messages.count) 消息")
    }
}
