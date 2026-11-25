import Foundation

/// Claude Code：会话在 `~/.claude/projects/<项目>/<session-id>.jsonl`，一行一条事件。
/// 只读；发送走 `claude -p --resume`，暂未实现。
public struct ClaudeCodeAdapter: AgentAdapter {
    public let agentID = "claude"

    private let root: URL
    private static let authLock = NSLock()
    private nonisolated(unsafe) static var authCache: (value: Bool, at: Date)?

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
                    title: title(of: file) == L10n.text("未命名会话")
                        ? (decodeProjectPath(dir.lastPathComponent)?.split(separator: "/").last.map(String.init) ?? L10n.text("未命名会话"))
                        : title(of: file),
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

    /// 发送前预检：CLI 不存在或未登录时，/v1/agents 直接把 canSend 置 false。
    /// 结果缓存 30 秒，避免每次 agentSummaries 都启动一个 CLI。
    public static func isLoggedIn(force: Bool = false) -> Bool {
        authLock.lock()
        if !force, let cached = authCache,
           Date().timeIntervalSince(cached.at) < 30 {
            let value = cached.value
            authLock.unlock()
            return value
        }
        authLock.unlock()

        guard let executable = executablePath() else {
            authLock.lock(); authCache = (false, Date()); authLock.unlock()
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["auth", "status"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            authLock.lock(); authCache = (false, Date()); authLock.unlock()
            return false
        }
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning { process.terminate() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        var loggedIn = false
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            loggedIn = obj["loggedIn"] as? Bool ?? false
        } else {
            loggedIn = text.contains("\"loggedIn\"") && text.contains("true")
        }
        authLock.lock()
        authCache = (loggedIn, Date())
        authLock.unlock()
        return loggedIn
    }

    /// `--resume` 要的是 session id（文件名 UUID），不是 JSONL 文件路径。
    static func resumeArguments(sessionID: String, text: String) -> [String] {
        ["-p", "--resume", sessionID, text]
    }

    /// 不同安装方式路径不同（npm 全局 / Homebrew / 官方安装器），都试一遍。
    static func executablePath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String? {
        var candidates = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude"
        ]
        if let path = environment["PATH"] {
            candidates.append(
                contentsOf: path.split(separator: ":").map(String.init)
                    .filter { !$0.isEmpty }
                    .map { URL(fileURLWithPath: $0).appendingPathComponent("claude").path }
            )
        }
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    public func send(_ text: String, to session: AgentSession) async throws {
        // `claude -p --resume <session-id> <text>`：非交互续写一轮
        guard let executable = Self.executablePath() else {
            throw AgentAdapterError.notFound
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Self.resumeArguments(sessionID: session.id, text: text)

        // 不要用 Pipe 直接接输出：长回答会填满管道缓冲区，进程永远不结束，
        // 看起来就像「Claude 没有在 10 分钟内结束」。用临时文件只读回诊断前缀。
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowcue-claude-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let log = try? FileHandle(forWritingTo: logURL) else {
            throw AgentAdapterError.malformed("无法创建 Claude 日志文件")
        }
        defer {
            try? log.close()
            try? FileManager.default.removeItem(at: logURL)
        }
        process.standardOutput = log
        process.standardError = log

        try process.run()
        let deadline = Date().addingTimeInterval(600)
        while process.isRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        if process.isRunning {
            process.terminate()
            throw AgentAdapterError.malformed("Claude 没有在 10 分钟内结束")
        }
        let output: String
        if let handle = try? FileHandle(forReadingFrom: logURL) {
            let data = (try? handle.read(upToCount: 4096)) ?? Data()
            try? handle.close()
            output = String(decoding: data, as: UTF8.self)
        } else {
            output = ""
        }
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
        guard let handle = try? FileHandle(forReadingFrom: file) else { return L10n.text("未命名会话") }
        defer { try? handle.close() }
        let chunk = handle.readData(ofLength: readLimit)
        guard let text = String(data: chunk, encoding: .utf8) else { return L10n.text("未命名会话") }

        var fallbackName: String?
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if fallbackName == nil, let cwd = obj["cwd"] as? String, !cwd.isEmpty {
                let last = (cwd as NSString).lastPathComponent
                if !last.isEmpty { fallbackName = last }
            }

            guard (obj["type"] as? String) == "user",
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
        if let fallbackName, fallbackName != "/" { return fallbackName }
        // 会话在根目录启动、又没有像样的用户消息时，用会话 id 短码兜底
        return "#" + file.deletingPathExtension().lastPathComponent.prefix(8)
    }
}
