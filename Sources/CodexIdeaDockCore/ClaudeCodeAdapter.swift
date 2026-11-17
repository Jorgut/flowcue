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

    public func listSessions(limit: Int = 50) async throws -> [AgentSession] {
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

    public func messages(in session: AgentSession, limit: Int = 60) async throws -> [AgentMessage] {
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
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !Self.isSystemPrompt(body) else { continue }

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
        // `claude -p --resume <session-id> <text>`：非交互续写一轮
        let executable = "/Users/\(NSUserName())/.local/bin/claude"
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw AgentAdapterError.notFound
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-p", "--resume", session.locator, text]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let deadline = Date().addingTimeInterval(600)
        while process.isRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        if process.isRunning {
            process.terminate()
            throw AgentAdapterError.malformed("Claude 没有在 10 分钟内结束")
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if process.terminationStatus != 0 {
            throw AgentAdapterError.malformed(output.isEmpty ? "Claude 执行失败" : String(output.prefix(200)))
        }
    }

    // MARK: helpers

    /// 有些工具会把系统提示词写成一条 user 消息，这里过滤掉。
    static func isSystemPrompt(_ text: String) -> Bool {
        let head = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return head.hasPrefix("<") || head.hasPrefix("Caveat:")
            || head.hasPrefix("SYSTEM:") || head.hasPrefix("You are ")
    }

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
            guard !body.isEmpty, !Self.isSystemPrompt(body) else { continue }
            return String(body.prefix(60))
        }
        return "未命名会话"
    }
}
