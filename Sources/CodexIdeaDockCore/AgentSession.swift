import Foundation

// MARK: - 通用模型（所有 agent 共用）

public struct AgentMessage: Identifiable, Hashable, Sendable {
    public enum Role: String, Sendable {
        case user, assistant, tool, system
    }

    public let id: String
    public let role: Role
    public let text: String
    public let timestamp: Date?

    public init(id: String, role: Role, text: String, timestamp: Date?) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
    }
}

public struct AgentSession: Identifiable, Hashable, Sendable {
    public let id: String            // 会话在 agent 内的标识
    public let agentID: String       // 对应 AgentDiscovery 的 id
    public let title: String
    public let updatedAt: Date
    public let projectPath: String?
    public let messageCount: Int?    // 能算就填，不能算为 nil
    public let locator: String       // 文件路径 / RPC id / URL，适配器自己解释

    public init(id: String, agentID: String, title: String, updatedAt: Date,
                projectPath: String?, messageCount: Int?, locator: String) {
        self.id = id
        self.agentID = agentID
        self.title = title
        self.updatedAt = updatedAt
        self.projectPath = projectPath
        self.messageCount = messageCount
        self.locator = locator
    }
}

// MARK: - 适配器协议
// 每家只写这三个方法；模型、排序、分页、UI 全部共用。

public protocol AgentAdapter: Sendable {
    var agentID: String { get }
    /// 列会话，按最近使用倒序
    func listSessions(limit: Int) async throws -> [AgentSession]
    /// 读一页消息，oldest → newest
    func messages(in session: AgentSession, limit: Int) async throws -> [AgentMessage]
    /// 发消息（暂不支持就 throw .unsupported）
    func send(_ text: String, to session: AgentSession) async throws
}

public enum AgentAdapterError: Error, Sendable {
    case unsupported
    case notFound
    case malformed(String)
}
