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

        // Sessions come from the local DSH session logs, not only from pending
        // approvals. Pending approvals are merged in as a per-session badge.
        let pending = (try? await client.pending()) ?? []
        var pendingCounts: [String: Int] = [:]
        for item in pending {
            guard let sessionID = item.sessionId else { continue }
            pendingCounts[sessionID, default: 0] += 1
        }

        let reader = DSHSessionReader()
        let localSessions = reader.sessions(limit: limit)
        var sessions: [AgentSession] = localSessions.map { session in
            let count = pendingCounts[session.id] ?? 0
            let title = count > 0 ? "\(session.title) · \(count) 个待审" : session.title
            return AgentSession(
                id: session.id,
                agentID: agentID,
                title: title,
                updatedAt: session.updatedAt,
                projectPath: session.projectDirectory,
                messageCount: nil,
                locator: session.id
            )
        }

        // Approvals whose session no longer appears in the local logs still
        // need a surface so the request is never silently lost.
        let known = Set(localSessions.map(\.id))
        let pendingOnly = pendingCounts
            .filter { !known.contains($0.key) }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { sessionID, count in
                AgentSession(
                    id: sessionID,
                    agentID: agentID,
                    title: "DSH 会话 · \(count) 个待审",
                    updatedAt: Date(),
                    projectPath: nil,
                    messageCount: nil,
                    locator: sessionID
                )
            }

        return Array((sessions + pendingOnly).prefix(limit))
    }

    public func messages(in session: AgentSession, limit: Int = 80) async throws -> [AgentMessage] {
        throw AgentAdapterError.unsupported
    }

    public func send(_ text: String, to session: AgentSession) async throws {
        try await client.send(sessionID: session.locator, text: text)
    }
}
