import Foundation

/// Codex：通过 `codex app-server` 的 JSON-RPC 读会话与对话。
/// 只读；发送（turn/start）留待下一步。
public struct CodexAgentAdapter: AgentAdapter {
    public let agentID = "codex"
    private let executableURL: URL
    private let timeout: TimeInterval
    private static let pathLock = NSLock()
    private nonisolated(unsafe) static var pathCache: [String: String] = [:]

    public init(executableURL: URL? = nil, timeout: TimeInterval = 20) {
        self.executableURL = executableURL
            ?? (try? CodexBridge.resolveCodexExecutable())
            ?? URL(fileURLWithPath: "/opt/homebrew/bin/codex")
        self.timeout = timeout
    }

    // MARK: AgentAdapter

    public func listSessions(limit: Int = 50) async throws -> [AgentSession] {
        let response = try call(method: "thread/list", id: 2, params: [
            "cursor": NSNull(),
            "limit": limit,
            "sortKey": "recency_at",
            "sortDirection": "desc",
            "archived": false,
            "useStateDbOnly": true,
            "sourceKinds": []
        ])
        guard let result = response["result"] as? [String: Any],
              let data = result["data"] as? [[String: Any]] else {
            throw AgentAdapterError.malformed("thread/list")
        }

        return data.compactMap { thread in
            guard let id = thread["id"] as? String else { return nil }
            let title = (thread["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? cleanPreview(thread["preview"] as? String)
            if let path = thread["path"] as? String {
                Self.pathLock.lock()
                Self.pathCache[id] = path
                Self.pathLock.unlock()
            }
            let seconds = (thread["updatedAt"] as? Double) ?? Double(thread["updatedAt"] as? Int ?? 0)
            return AgentSession(
                id: id,
                agentID: agentID,
                title: title,
                updatedAt: Date(timeIntervalSince1970: seconds),
                projectPath: thread["cwd"] as? String,
                messageCount: nil,
                locator: id
            )
        }
    }

    public func messages(in session: AgentSession, limit: Int = 80) async throws -> [AgentMessage] {
        let response = try call(method: "thread/read", id: 3, params: [
            "threadId": session.locator,
            "includeTurns": true
        ])
        guard let result = response["result"] as? [String: Any],
              let thread = result["thread"] as? [String: Any],
              let turns = thread["turns"] as? [[String: Any]] else {
            throw AgentAdapterError.malformed("thread/read")
        }

        var out: [AgentMessage] = []
        for turn in turns {
            guard let items = turn["items"] as? [[String: Any]] else { continue }
            for item in items {
                guard let type = item["type"] as? String else { continue }
                let id = item["id"] as? String ?? UUID().uuidString
                switch type {
                case "userMessage":
                    let text = (item["content"] as? [[String: Any]])?
                        .filter { ($0["type"] as? String) == "text" }
                        .compactMap { $0["text"] as? String }
                        .joined(separator: "\n") ?? ""
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        out.append(AgentMessage(id: id, role: .user, text: text, timestamp: nil))
                    }
                case "agentMessage":
                    let text = item["text"] as? String ?? ""
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        out.append(AgentMessage(id: id, role: .assistant, text: text, timestamp: nil))
                    }
                default:
                    continue
                }
            }
        }
        return Array(out.suffix(limit))
    }

    /// Codex 没有 app-server 的实时 activity 字段；从会话 JSONL 尾部的
    /// task_started/task_complete 推断。超过 90 秒没有新事件就视为中断，
    /// 避免被中断的 turn 永远显示“正在执行”。
    public func activity(in session: AgentSession) -> String? {
        let path: String?
        Self.pathLock.lock()
        path = Self.pathCache[session.id]
        Self.pathLock.unlock()
        guard let path else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > 512 * 1024 ? size - 512 * 1024 : 0
        try? handle.seek(toOffset: start)
        let data = handle.readDataToEndOfFile()
        var active = false
        var sawEvent = false
        for line in data.split(separator: 0x0A) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  let type = payload["type"] as? String else { continue }
            switch type {
            case "task_started":
                active = true
                sawEvent = true
            case "task_complete", "task_failed", "turn_aborted":
                active = false
                sawEvent = true
            default:
                break
            }
        }
        guard sawEvent, active else { return nil }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) > 90 {
            return nil
        }
        return L10n.text("Codex 正在执行…")
    }

    public func send(_ text: String, to session: AgentSession) async throws {
        // 复用已有队列通道：`codex queue --thread <id> --message <text>`
        let outcome = await CodexBridge().queue(message: text, to: session.locator)
        switch outcome {
        case .queued:
            return
        case .failed(_, let message), .unknown(let message):
            throw AgentAdapterError.malformed(message)
        }
    }

    // MARK: JSON-RPC over stdio

    private func call(method: String, id: Int, params: [String: Any]) throws -> [String: Any] {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["app-server"]

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var buffer = Data()
        }
        let box = Box()
        var found: [String: Any]?

        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            box.lock.lock(); box.buffer.append(chunk); box.lock.unlock()
        }

        do { try process.run() } catch { throw AgentAdapterError.malformed("无法启动 codex app-server") }

        func write(_ object: [String: Any]) throws {
            guard JSONSerialization.isValidJSONObject(object) else {
                throw AgentAdapterError.malformed("请求无法序列化")
            }
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: data)
        }

        try write(["method": "initialize", "id": 1,
                   "params": ["clientInfo": ["name": "flowcue_agent_browser", "title": "FlowCue", "version": "0.1.0"]]])
        try write(["method": "initialized"])
        try write(["method": method, "id": id, "params": params])

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            box.lock.lock()
            let data = box.buffer
            box.lock.unlock()
            for line in data.split(separator: 0x0A) {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                if (object["id"] as? Int) == id {
                    found = object
                    break
                }
            }
            if found != nil { break }
            usleep(50_000)
        }

        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }

        guard let found else { throw AgentAdapterError.notFound }
        return found
    }

    private func cleanPreview(_ preview: String?) -> String {
        guard let preview else { return "未命名会话" }
        let cleaned = preview
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "未命名会话" : String(cleaned.prefix(60))
    }
}
