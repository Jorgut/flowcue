import Foundation

/// UI 只跟这一层打交道：按 agent 拿适配器，再读写会话。
public struct AgentService: Sendable {
    private let adapters: [String: any AgentAdapter]

    public init(adapters: [any AgentAdapter]) {
        var map: [String: any AgentAdapter] = [:]
        for adapter in adapters { map[adapter.agentID] = adapter }
        self.adapters = map
    }

    public static var `default`: AgentService {
        AgentService(adapters: [
            ClaudeCodeAdapter(),
            CodexAgentAdapter(),
            DSHAgentAdapter()
        ])
    }

    public func adapter(for agentID: String) -> (any AgentAdapter)? { adapters[agentID] }
    public var supportedAgentIDs: [String] { adapters.keys.sorted() }

    public func sessions(for agentID: String, limit: Int = 50) async throws -> [AgentSession] {
        guard let adapter = adapters[agentID] else { throw AgentAdapterError.unsupported }
        return try await adapter.listSessions(limit: limit)
    }

    public func messages(_ session: AgentSession, limit: Int = 80) async throws -> [AgentMessage] {
        guard let adapter = adapters[session.agentID] else { throw AgentAdapterError.unsupported }
        return try await adapter.messages(in: session, limit: limit)
    }

    public func send(_ text: String, to session: AgentSession) async throws {
        guard let adapter = adapters[session.agentID] else { throw AgentAdapterError.unsupported }
        try await adapter.send(text, to: session)
    }
}
