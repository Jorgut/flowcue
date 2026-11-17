import Foundation

/// 会话收藏（归档）：只在本机记录「哪些会话被星标」，不改 agent 自己的数据。
public enum AgentSessionArchive {
    private static let key = "FlowCue.starredSessions"
    nonisolated(unsafe) public static var defaults: UserDefaults = .standard

    private static func raw() -> [String] { defaults.stringArray(forKey: key) ?? [] }

    public static func isStarred(agentID: String, sessionID: String) -> Bool {
        raw().contains("\(agentID)|\(sessionID)")
    }

    public static func toggle(agentID: String, sessionID: String) -> Bool {
        var items = raw()
        let token = "\(agentID)|\(sessionID)"
        if let index = items.firstIndex(of: token) {
            items.remove(at: index)
            defaults.set(items, forKey: key)
            return false
        }
        items.append(token)
        defaults.set(items, forKey: key)
        return true
    }

    public static func starredIDs(agentID: String) -> [String] {
        raw().filter { $0.hasPrefix("\(agentID)|") }.map { String($0.split(separator: "|", maxSplits: 1).last ?? "") }
    }
}
