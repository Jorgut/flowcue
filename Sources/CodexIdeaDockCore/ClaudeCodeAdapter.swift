import Foundation

/// Claude Code：会话在 `~/.claude/projects/<项目>/<session-id>.jsonl`，一行一条事件。
/// 只读；发送走 `claude -p --resume`，暂未实现。
public struct ClaudeCodeAdapter: AgentAdapter {
    public let agentID = "claude"
    private let root: URL

    public init(root: URL? = nil) {
        self.root = root ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    public func listSessions(limit: Int = 50) throws -> [AgentSession] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            throw AgentAdapterError.notFound
        }

        var sessions: [AgentSession] = []
        for dir in projectDirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                let updated = values?.contentModificationDate ?? .distantPast
                let id = file.deletingPathExtension().lastPathComponent
                sessions.append(AgentSession(
                    id: id,
                    agentID: agentID,
                    title: title(of: file),
                    updatedAt: updated,
                    projectPath: decodeProjectPath(dir.lastPathComponent),
                    messageCount: nil,
                    locator: file.path
                ))
            }
        }
        return Array(sessions.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
    }

    public func messages(in session: AgentSession, limit: Int = 60) throws -> [AgentMessage] {
        let url = URL(fileURLWithPath: session.locator)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw AgentAdapterError.notFound
        }

        var out: [AgentMessage] = []
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String,
                  type == "user" || type == "assistant",
                  (obj["isSidechain"] as? Bool) != true,
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]]
            else { continue }

            let body = content
                .filter { ($0["type"] as? String) == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            out.append(AgentMessage(
                id: obj["uuid"] as? String ?? UUID().uuidString,
                role: type == "user" ? .user : .assistant,
                text: body,
                timestamp: (obj["timestamp"] as? String).flatMap(Self.parseDate)
            ))
        }
        return Array(out.suffix(limit))
    }

    public func send(_ text: String, to session: AgentSession) async throws {
        throw AgentAdapterError.unsupported
    }

    // MARK: helpers

    private static func parseDate(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    /// `-Users-aj-ClaudeWork` → `/Users/aj/ClaudeWork`
    private func decodeProjectPath(_ encoded: String) -> String? {
        guard encoded.hasPrefix("-") else { return nil }
        return encoded.replacingOccurrences(of: "-", with: "/")
    }

    /// 首条像样的用户消息前 60 字，作为标题；跳过系统注入与工具结果。
    private func title(of file: URL) -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        let readLimit = min(max(size, 64 * 1024), 4 * 1024 * 1024)
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "未命名会话" }
        defer { try? handle.close() }
        let chunk = handle.readData(ofLength: readLimit)
        guard let text = String(data: chunk, encoding: .utf8) else { return "未命名会话" }

        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["type"] as? String) == "user",
                  (obj["isSidechain"] as? Bool) != true,
                  let message = obj["message"] as? [String: Any]
            else { continue }

            var body = ""
            if let string = message["content"] as? String {
                body = string
            } else if let blocks = message["content"] as? [[String: Any]] {
                body = blocks.compactMap { $0["text"] as? String }.joined(separator: " ")
            }
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
            // 系统注入的提醒 / 工具输出不作为标题
            guard !body.isEmpty, !body.hasPrefix("<"), !body.hasPrefix("Caveat:") else { continue }
            return String(body.prefix(60))
        }
        return "未命名会话"
    }
}
