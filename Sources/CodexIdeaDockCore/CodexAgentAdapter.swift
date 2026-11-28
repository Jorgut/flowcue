import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Codex：通过 `codex app-server` 的 JSON-RPC 读会话与对话。
/// 图片由 CodexBridge 通过 App Server 投递。
public struct CodexAgentAdapter: AgentAdapter {
    public let agentID = "codex"
    private let executableURL: URL
    private let timeout: TimeInterval
    private static let pathLock = NSLock()
    /// Codex app-server uses the shared state DB; two concurrent short-lived
    /// app-servers can deadlock each other and both time out. Serialize calls.
    private static let callLock = NSLock()
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
        try threadMessages(in: session, limit: limit, includeProgress: false)
    }

    func timeline(in session: AgentSession, limit: Int) throws -> [AgentMessage] {
        try threadMessages(in: session, limit: limit, includeProgress: true)
    }

    private func threadMessages(in session: AgentSession, limit: Int, includeProgress: Bool) throws -> [AgentMessage] {
        let response = try call(method: "thread/read", id: 3, params: [
            "threadId": session.locator,
            "includeTurns": true
        ])
        guard let result = response["result"] as? [String: Any],
              let thread = result["thread"] as? [String: Any],
              let turns = thread["turns"] as? [[String: Any]] else {
            throw AgentAdapterError.malformed("thread/read")
        }

        return Self.parseTurns(turns, limit: limit, includeProgress: includeProgress)
    }

    static func parseTurns(_ turns: [[String: Any]], limit: Int, includeProgress: Bool) -> [AgentMessage] {
        var out: [AgentMessage] = []
        for (turnIndex, turn) in turns.enumerated() {
            guard let items = turn["items"] as? [[String: Any]] else { continue }
            for (itemIndex, item) in items.enumerated() {
                guard let type = item["type"] as? String else { continue }
                let id = item["id"] as? String ?? "codex-\(turnIndex)-\(itemIndex)"
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
                    if includeProgress, let progress = Self.progress(from: item, type: type) {
                        out.append(AgentMessage(id: id, role: .tool, text: "", timestamp: nil, progress: progress))
                    }
                }
            }
        }
        return Array(out.suffix(limit))
    }

    private static func progress(from item: [String: Any], type: String) -> AgentProgress? {
        if type == "plan" { return .init(kind: .plan, state: .completed) }
        guard let rawState = item["status"] as? String,
              let state = AgentProgress.State(rawValue: rawState) else { return nil }
        switch type {
        case "commandExecution": return .init(kind: .command, state: state)
        case "fileChange": return .init(kind: .edit, state: state)
        case "mcpToolCall", "dynamicToolCall":
            let tool = item["tool"] as? String
            let namespace = ((item["server"] ?? item["namespace"]) as? String)?
                .lowercased().filter(\.isLetter)
            let isSummary = tool == "mcp__codex_app__update_running_summary"
                || (tool == "update_running_summary" && ["codexapp", "mcpcodexapp"].contains(namespace ?? ""))
            guard isSummary else { return .init(kind: .tool, state: state) }
            let labels = (item["arguments"] as? [String: Any])?["labels"] as? [String] ?? []
            let label = (state == .completed ? labels.last : labels.first)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = label.flatMap { candidate in
                candidate.isEmpty || candidate.count > 100 || candidate.contains(where: \.isNewline)
                    ? nil : candidate
            }
            return .init(kind: .step, state: state, title: title)
        default: return nil
        }
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

    func sendImages(_ message: RemoteCodexImageMessage, to session: AgentSession,
                    bridge: CodexBridge = CodexBridge(),
                    stagingRoot: URL = URL.applicationSupportDirectory.appendingPathComponent("FlowCueRemote/CodexImages")) async throws -> QueueDeliveryOutcome {
        let manager = FileManager.default
        try manager.createDirectory(at: stagingRoot, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        // A queued turn can outlive the CLI. Prune only our expired staging folders.
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey]
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        for entry in (try? manager.contentsOfDirectory(at: stagingRoot, includingPropertiesForKeys: Array(keys))) ?? [] {
            guard UUID(uuidString: entry.lastPathComponent) != nil,
                  let values = try? entry.resourceValues(forKeys: keys),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  let created = values.creationDate, created < cutoff else { continue }
            try? manager.removeItem(at: entry)
        }
        let folder = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        var retain = false
        defer { if !retain { try? manager.removeItem(at: folder) } }
        let files = try message.images.enumerated().map { index, data in
            let file = folder.appendingPathComponent("image-\(index + 1).jpg")
            try data.write(to: file, options: .withoutOverwriting)
            return file.path
        }
        let prepared = try await Self.prepareAttachments(files)
        let result = await bridge.queue(message: message.text, to: session.locator, imagePaths: prepared)
        // Keep the accepted turn's image files available to Codex history.
        switch result {
        case .queued, .unknown: retain = true
        case .failed: break
        }
        return result
    }

    private static func prepareAttachments(_ paths: [String]) async throws -> [String] {
        try await Task.detached(priority: .userInitiated) {
            let budget = 192 * 1024
            let files = paths.map { URL(fileURLWithPath: $0) }
            let total = try files.reduce(0) { sum, file in
                sum + (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            }
            guard total > budget else { return paths }
            let folder = files[0].deletingLastPathComponent().appendingPathComponent("prepared")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return try files.map { file in
                guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else {
                    throw AgentAdapterError.malformed("Invalid image attachment")
                }
                let target = folder.appendingPathComponent(file.lastPathComponent)
                for side in [1600, 1200, 900, 640, 480, 320, 240] {
                    let options: [CFString: Any] = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: side
                    ]
                    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { continue }
                    let jpeg = NSMutableData()
                    guard let encoder = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
                    let compression = [kCGImageDestinationLossyCompressionQuality: 0.55] as CFDictionary
                    CGImageDestinationAddImage(encoder, image, compression)
                    guard CGImageDestinationFinalize(encoder), jpeg.length <= budget / paths.count else { continue }
                    try (jpeg as Data).write(to: target, options: .atomic)
                    return target.path
                }
                throw AgentAdapterError.malformed("Image attachment exceeds the delivery budget")
            }
        }.value
    }

    static func isValidAttachment(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.jpeg",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int else { return false }
        return (1...2048).contains(width) && (1...2048).contains(height)
    }

    @MainActor
    struct ImageBatch {
        let folder: URL
        let sessionID: UUID
        private var marker: URL { folder.appendingPathComponent("delivery") }

        init(sessionID: UUID, batchID: UUID, root: URL = URL.applicationSupportDirectory
            .appendingPathComponent("FlowCueRemote/CodexImageBatches")) {
            self.sessionID = sessionID
            folder = root.appendingPathComponent(sessionID.uuidString).appendingPathComponent(batchID.uuidString)
        }

        func uploaded() -> [Int] {
            (0..<RemoteCodexImageMessage.batchMaxImages).filter {
                FileManager.default.fileExists(atPath: file($0).path)
            }
        }

        func deliveryStatus() -> Int {
            guard let value = try? String(contentsOf: marker, encoding: .utf8) else { return 404 }
            return value == "200" ? 200 : 409
        }

        func stage(_ data: Data, at index: Int) throws -> Int {
            guard (0..<RemoteCodexImageMessage.batchMaxImages).contains(index) else { return 400 }
            guard data.count <= RemoteCodexImageMessage.maxImageBytes else { return 413 }
            guard CodexAgentAdapter.isValidAttachment(data) else { return 415 }
            let target = file(index)
            if let existing = try? Data(contentsOf: target) {
                return existing == data ? 200 : 409
            }
            guard !FileManager.default.fileExists(atPath: marker.path) else { return 409 }
            if !FileManager.default.fileExists(atPath: folder.path) {
                let parent = folder.deletingLastPathComponent()
                let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey]
                let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
                for entry in (try? FileManager.default.contentsOfDirectory(
                    at: parent, includingPropertiesForKeys: Array(keys)
                )) ?? [] {
                    guard UUID(uuidString: entry.lastPathComponent) != nil,
                          let values = try? entry.resourceValues(forKeys: keys),
                          values.isDirectory == true, values.isSymbolicLink != true,
                          let created = values.creationDate, created < cutoff else { continue }
                    try? FileManager.default.removeItem(at: entry)
                }
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: target, options: .atomic)
            return 200
        }

        func submit(_ batch: RemoteCodexImageBatch, bridge: CodexBridge = CodexBridge()) async throws -> Int {
            guard (1...RemoteCodexImageMessage.batchMaxImages).contains(batch.count) else { return 400 }
            guard batch.text.utf8.count <= RemoteCodexImageMessage.maxTextBytes else { return 413 }
            if let result = try? String(contentsOf: marker, encoding: .utf8) {
                return Int(result) ?? 409
            }
            guard uploaded() == Array(0..<batch.count) else { return 424 }
            try Data("409".utf8).write(to: marker, options: .withoutOverwriting)
            let paths = (0..<batch.count).map { file($0).path }
            let prepared: [String]
            do {
                prepared = try await CodexAgentAdapter.prepareAttachments(paths)
            } catch {
                try FileManager.default.removeItem(at: marker)
                return 413
            }
            let receipt = marker
            let outcome = await bridge.queue(message: batch.text, to: sessionID.uuidString.lowercased(), imagePaths: prepared) {
                try? Data("200".utf8).write(to: receipt, options: .atomic)
            }
            switch outcome {
            case .unknown: return 409
            case .failed(_, let message):
                try FileManager.default.removeItem(at: marker)
                if message == QueueDeliveryDiagnostic.targetBusy.rawValue { return 423 }
                return 422
            case .queued:
                try Data("200".utf8).write(to: marker, options: .atomic)
                return 200
            }
        }

        private func file(_ index: Int) -> URL { folder.appendingPathComponent("image-\(index + 1).jpg") }
    }

    // MARK: JSON-RPC over stdio

    private func call(method: String, id: Int, params: [String: Any]) throws -> [String: Any] {
        Self.callLock.lock()
        defer { Self.callLock.unlock() }
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
