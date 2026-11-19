import Foundation

/// 未读回复计数。
///
/// 只保存 `agentID:sessionID` 与标记时间，不保存回复正文；用于菜单栏角标。
/// 规则：检测到一轮新回复时标记未读，用户打开该会话或回到 Agent 列表时清除。
public final class ReplyUnreadStore {
    public static let defaultKey = "FlowCue.unreadReplies"

    private let defaults: UserDefaults
    private let key: String
    private var entries: [String: TimeInterval]

    /// 计数变化回调（主线程调用方自行切线程）
    public var onChange: (() -> Void)?

    public init(defaults: UserDefaults = .standard, key: String = ReplyUnreadStore.defaultKey) {
        self.defaults = defaults
        self.key = key
        self.entries = defaults.dictionary(forKey: key) as? [String: TimeInterval] ?? [:]
    }

    public var count: Int { entries.count }

    public var keys: Set<String> { Set(entries.keys) }

    public static func key(agentID: String, sessionID: String) -> String {
        "\(agentID):\(sessionID)"
    }

    /// 标记一个会话有未读回复；同一会话重复标记不会重复计数。
    @discardableResult
    public func markUnread(agentID: String, sessionID: String, at date: Date = Date()) -> Bool {
        let key = Self.key(agentID: agentID, sessionID: sessionID)
        guard entries[key] == nil else { return false }
        entries[key] = date.timeIntervalSince1970
        persist()
        return true
    }

    /// 用户看过该会话后清除；返回是否真的清掉了。
    @discardableResult
    public func markRead(agentID: String, sessionID: String) -> Bool {
        let key = Self.key(agentID: agentID, sessionID: sessionID)
        guard entries.removeValue(forKey: key) != nil else { return false }
        persist()
        return true
    }

    @discardableResult
    public func clearAll() -> Bool {
        guard !entries.isEmpty else { return false }
        entries.removeAll()
        persist()
        return true
    }

    private func persist() {
        defaults.set(entries, forKey: key)
        onChange?()
    }
}
