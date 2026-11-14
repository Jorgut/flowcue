import Foundation

/// DSH：通过本机桥接（`~/.flowcue/dsh-bridge.json` + loopback HTTP）。
/// 桥目前只暴露「待审请求 / 发消息 / 决策」，所以会话列表由待审请求推出，
/// 对话内容读不了；这两点等桥端补端点。
public struct DSHAgentAdapter: AgentAdapter {
    public let agentID = "dsh"
    private let client: DSHBridgeClient

    public init(client: DSHBridgeClient = DSHBridgeClient()) {
        self.client = client
    }

    public func listSessions(limit: Int = 50) async throws -> [AgentSession] {
        guard client.isConfigured else { throw AgentAdapterError.notFound }
        let pending = try await client.pending()

        var bySession: [String: Int] = [:]
        for item in pending {
            guard let sessionID = item.sessionId else { continue }
            bySession[sessionID, default: 0] += 1
        }

        let now = Date()
        return bySession
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { sessionID, count in
                AgentSession(
                    id: sessionID,
                    agentID: agentID,
                    title: "DSH 会话 · \(count) 个待审",
                    updatedAt: now,
                    projectPath: nil,
                    messageCount: nil,
                    locator: sessionID
                )
            }
    }

    public func messages(in session: AgentSession, limit: Int = 80) async throws -> [AgentMessage] {
        throw AgentAdapterError.unsupported
    }

    public func send(_ text: String, to session: AgentSession) async throws {
        try await client.send(sessionID: session.locator, text: text)
    }
}
