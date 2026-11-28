import XCTest
@testable import CodexIdeaDockCore

final class CodexAgentAdapterTests: XCTestCase {
    func testTimelineKeepsSafeStepsAndUpdatesCommandsInPlace() throws {
        let items: [[String: Any]] = [
            ["id": "u", "type": "userMessage", "content": [["type": "text", "text": "Check"]]],
            ["id": "step", "type": "mcpToolCall", "server": "codex-app", "tool": "update_running_summary",
             "status": "completed", "arguments": ["labels": ["Checking UI", "Checked UI"], "token": "secret"]],
            ["id": "cmd", "type": "commandExecution", "status": "inProgress", "command": "secret command",
             "cwd": "/private/path", "aggregatedOutput": "secret output"],
            ["id": "a", "type": "agentMessage", "text": "Visible reply"]
        ]
        let parsed = CodexAgentAdapter.parseTurns([["items": items]], limit: 20, includeProgress: true)
        XCTAssertEqual(parsed.map(\.id), ["u", "step", "cmd", "a"])
        XCTAssertEqual(parsed[1].progress, .init(kind: .step, state: .completed, title: "Checked UI"))
        XCTAssertEqual(parsed[2].progress, .init(kind: .command, state: .inProgress))
        XCTAssertEqual(parsed[2].text, "")
        XCTAssertEqual(CodexAgentAdapter.parseTurns([["items": items]], limit: 20, includeProgress: false)
            .map(\.id), ["u", "a"])

        var updatedItems = items
        updatedItems[2]["status"] = "failed"
        let updated = CodexAgentAdapter.parseTurns([["items": updatedItems]], limit: 20, includeProgress: true)
            .map { RemoteAgentMessage(id: $0.id, role: $0.role.rawValue, text: $0.text, timestamp: $0.timestamp,
                                      progress: $0.progress) }
        let page = RemoteAgentMessagePage.window(in: updated, before: nil, after: "a")
        XCTAssertTrue(page.messages.isEmpty)
        XCTAssertEqual(page.progressUpdates?.last?.id, "cmd")
        XCTAssertEqual(page.progressUpdates?.last?.progress?.state, .failed)
        let payload = String(decoding: try JSONEncoder().encode(page), as: UTF8.self)
        ["secret", "private/path", "aggregatedOutput"].forEach { XCTAssertFalse(payload.contains($0)) }
    }

    func testListAndReadCodexThreads() async throws {
        let adapter = CodexAgentAdapter()
        let sessions: [AgentSession]
        do {
            sessions = try await adapter.listSessions(limit: 3)
        } catch {
            throw XCTSkip("codex app-server 不可用：\(error)")
        }
        try XCTSkipIf(sessions.isEmpty, "没有 Codex 会话")

        for s in sessions {
            print("• \(s.title.prefix(50))  |  \(s.projectPath ?? "-")  |  \(s.updatedAt)")
        }

        let messages = try await adapter.messages(in: sessions[0], limit: 10)
        XCTAssertFalse(messages.isEmpty)
        for m in messages.suffix(3) {
            print("  [\(m.role.rawValue)] \(m.text.prefix(60).replacingOccurrences(of: "\n", with: " "))")
        }
    }
}
