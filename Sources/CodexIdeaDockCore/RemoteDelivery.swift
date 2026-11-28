import Foundation
import CryptoKit

/// One idea pushed from the paired iPhone over the LAN.
public struct RemoteIdea: Codable, Identifiable, Sendable {
    public let id: UUID
    public let text: String
    public let createdAt: Date
    public let updatedAt: Date
    /// 状态原始值；旧版 Mac/手机不带这个字段时按 saved 处理。
    public let status: String?
    /// 墓碑时间；非空表示这条已被删除。
    public let deletedAt: Date?

    public init(
        id: UUID,
        text: String,
        createdAt: Date,
        updatedAt: Date,
        status: String? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.status = status
        self.deletedAt = deletedAt
    }
}

public struct RemoteDeliveryRequest: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let phoneID: UUID
    public let executorID: UUID
    public let targetThreadID: UUID
    public let text: String

    /// Construct only from an explicit Send action, never from note sync.
    public init(id: UUID = UUID(), phoneID: UUID, executorID: UUID, targetThreadID: UUID, text: String) {
        self.id = id
        self.phoneID = phoneID
        self.executorID = executorID
        self.targetThreadID = targetThreadID
        self.text = text
    }
}

public enum RemoteDeliveryState: String, Codable, Sendable {
    case processing, delivered, failed, uncertain
}

public enum RemoteDeliveryError: Error {
    case unpairedDevice
    case wrongExecutor
    case emptyMessage
    case conflictingRequest
}

/// A durable local gate for the designated Mac. Cloud claims/pairing are a separate layer.
/// After interruption, processing is uncertain and must never be retried automatically.
@MainActor
public final class RemoteDeliveryGate {
    private struct Attempt: Codable {
        let fingerprint: String
        var state: RemoteDeliveryState
    }
    private let executorID: UUID
    private let ledgerURL: URL
    private let bridge: any CodexBridging
    private var attempts: [String: Attempt]

    public init(executorID: UUID, ledgerURL: URL, bridge: any CodexBridging) throws {
        self.executorID = executorID
        self.ledgerURL = ledgerURL
        self.bridge = bridge
        if FileManager.default.fileExists(atPath: ledgerURL.path) {
            attempts = try JSONDecoder().decode([String: Attempt].self, from: Data(contentsOf: ledgerURL))
        } else {
            attempts = [:]
        }
        for id in attempts.keys where attempts[id]?.state == .processing {
            attempts[id]?.state = .uncertain
        }
        try persist()
    }

    public func deliver(_ request: RemoteDeliveryRequest, pairedPhones: Set<UUID>) async throws -> RemoteDeliveryState {
        guard request.executorID == executorID else { throw RemoteDeliveryError.wrongExecutor }
        guard pairedPhones.contains(request.phoneID) else { throw RemoteDeliveryError.unpairedDevice }
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteDeliveryError.emptyMessage
        }
        let key = request.id.uuidString
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let fingerprint = SHA256.hash(data: try encoder.encode(request)).map { String(format: "%02x", $0) }.joined()
        if let attempt = attempts[key] {
            guard attempt.fingerprint == fingerprint else { throw RemoteDeliveryError.conflictingRequest }
            return attempt.state
        }
        attempts[key] = Attempt(fingerprint: fingerprint, state: .processing)
        do { try persist() } catch {
            attempts.removeValue(forKey: key)
            throw error
        }
        let result = await bridge.queue(message: request.text, to: request.targetThreadID.uuidString)
        let state: RemoteDeliveryState
        switch result {
        case .queued: state = .delivered
        case .failed: state = .failed
        case .unknown: state = .uncertain
        }
        attempts[key]?.state = state
        do { try persist() } catch {
            attempts[key]?.state = .uncertain
            throw error
        }
        return state
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(attempts).write(to: ledgerURL, options: .atomic)
    }
}

// MARK: - Remote continuation (phone -> paired Mac -> Codex)

public struct RemoteThreadSnapshot: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var title: String
    public var projectDirectory: String?
    public var lastReply: String
    public var updatedAt: Date
    public var executorID: UUID

    public init(id: String, title: String, projectDirectory: String?, lastReply: String, updatedAt: Date, executorID: UUID) {
        self.id = id
        self.title = title
        self.projectDirectory = projectDirectory
        self.lastReply = lastReply
        self.updatedAt = updatedAt
        self.executorID = executorID
    }
}

public struct RemoteCommand: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let phoneID: UUID
    public let executorID: UUID
    public let threadID: String
    public let text: String
    public let images: [String]?
    public let createdAt: Date

    public init(id: UUID = UUID(), phoneID: UUID, executorID: UUID, threadID: String, text: String, images: [String]? = nil, createdAt: Date = Date()) {
        self.id = id
        self.phoneID = phoneID
        self.executorID = executorID
        self.threadID = threadID
        self.text = text
        self.images = images
        self.createdAt = createdAt
    }
}

public struct RemoteCommandResult: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let state: RemoteDeliveryState
    public let reply: String?
    public let updatedAt: Date

    public init(id: UUID, state: RemoteDeliveryState, reply: String?, updatedAt: Date = Date()) {
        self.id = id
        self.state = state
        self.reply = reply
        self.updatedAt = updatedAt
    }
}

public enum RemoteContinuationError: Error {
    case wrongExecutor
    case invalidThread
    case emptyMessage
    case conflictingRequest
}

public struct DSHRemoteMessage: Codable, Sendable {
    public let sessionId: String
    public let text: String
    public let images: [String]?
    /// 客户端重试复用同一个 id；Mac 据此避免重复发 DSH turn。
    public let requestID: String?

    public init(sessionId: String, text: String, images: [String]? = nil, requestID: String? = nil) {
        self.sessionId = sessionId
        self.text = text
        self.images = images
        self.requestID = requestID
    }
}

public struct DSHSessionSnapshot: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let projectDirectory: String
    public let updatedAt: Date
    public let isSubagent: Bool
    public let parentSessionID: String?

    public init(
        id: String,
        title: String,
        projectDirectory: String,
        updatedAt: Date,
        isSubagent: Bool = false,
        parentSessionID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.projectDirectory = projectDirectory
        self.updatedAt = updatedAt
        self.isSubagent = isSubagent
        self.parentSessionID = parentSessionID
    }
}

public struct RemoteMessageImage: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let mediaType: String
    public let base64: String

    public init(id: String, mediaType: String, base64: String) {
        self.id = id
        self.mediaType = mediaType
        self.base64 = base64
    }
}

public struct RemoteConversationMessage: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let role: String
    public let text: String
    public let timestamp: Date?
    public let images: [RemoteMessageImage]?

    public init(
        id: String,
        role: String,
        text: String,
        timestamp: Date? = nil,
        images: [RemoteMessageImage]? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.images = images
    }
}

/// Reads the local Codex rollout for a thread. It only exposes user/assistant
/// message text, never tool output or raw CLI diagnostics.
public struct CodexSessionReplyReader: Sendable {
    private let sessionsDirectory: URL

    public init(sessionsDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")) {
        self.sessionsDirectory = sessionsDirectory
    }

    public func latestAssistantText(threadID: String, after: Date? = nil) -> String? {
        let target = threadID.lowercased()
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var files: [(URL, Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl", url.lastPathComponent.lowercased().contains(target) else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            files.append((url, values?.contentModificationDate ?? .distantPast))
        }
        return files.sorted { $0.1 > $1.1 }.lazy.compactMap { file in
            lastAssistantText(in: file.0, after: after)
        }.first
    }

    private func lastAssistantText(in url: URL, after: Date?) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let readSize = min(size, 2_000_000)
        guard size > 0 else { return nil }
        try? handle.seek(toOffset: size - readSize)
        guard let data = try? handle.readToEnd() else { return nil }
        var result: String?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if let raw = object["timestamp"] as? String, let date = Self.isoDate(raw), let after, date < after { continue }
            guard object["type"] as? String == "response_item",
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "message",
                  payload["role"] as? String == "assistant",
                  let content = payload["content"] as? [[String: Any]] else { continue }
            let text = content.compactMap { item -> String? in
                if let value = item["text"] as? String, !value.isEmpty { return value }
                return nil
            }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { result = String(text.prefix(20_000)) }
        }
        return result
    }

    public func messages(threadID: String, limit: Int = 80) -> [RemoteConversationMessage] {
        let target = threadID.lowercased()
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [(URL, Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl", url.lastPathComponent.lowercased().contains(target) else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            files.append((url, values?.contentModificationDate ?? .distantPast))
        }
        guard let newest = files.sorted(by: { $0.1 > $1.1 }).first else { return [] }
        guard let data = try? Data(contentsOf: newest.0, options: [.mappedIfSafe]) else { return [] }

        var result: [RemoteConversationMessage] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "response_item",
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "message",
                  let role = payload["role"] as? String,
                  role == "user" || role == "assistant",
                  let content = payload["content"] as? [[String: Any]] else { continue }
            let text = content.compactMap { item -> String? in
                guard let value = item["text"] as? String else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }.joined(separator: "\n")
            let images = content.compactMap { item -> RemoteMessageImage? in
                guard item["type"] as? String == "input_image",
                      let url = item["image_url"] as? String,
                      let comma = url.firstIndex(of: ",") else { return nil }
                let header = String(url[..<comma])
                let encoded = String(url[url.index(after: comma)...])
                guard header.contains(";base64") else { return nil }
                let mediaType = header
                    .replacingOccurrences(of: "data:", with: "")
                    .replacingOccurrences(of: ";base64", with: "")
                return RemoteMessageImage(id: "\(role)-\(result.count)-img-\(UUID().uuidString)", mediaType: mediaType, base64: encoded)
            }
            guard !text.isEmpty || !images.isEmpty else { continue }
            // Codex injects synthetic context/page markers as user messages.
            if role == "user", text.hasPrefix("<"), text.hasSuffix(">") { continue }
            let timestamp = (object["timestamp"] as? String).flatMap(Self.isoDate)
            result.append(RemoteConversationMessage(
                id: "\(result.count)-\(role)",
                role: role,
                text: String(text.prefix(20_000)),
                timestamp: timestamp,
                images: images.isEmpty ? nil : images
            ))
        }
        return Array(result.suffix(limit))
    }

    private static func isoDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

@MainActor
public protocol RemoteContinuationTransport: AnyObject {
    func fetchThreads() async throws -> [RemoteThreadSnapshot]
    func publishThreads(_ threads: [RemoteThreadSnapshot]) async throws
    func sendCommand(_ command: RemoteCommand) async throws
    func fetchCommands(executorID: UUID) async throws -> [RemoteCommand]
    func publishResult(_ result: RemoteCommandResult) async throws
    func fetchResults(ids: [UUID]) async throws -> [RemoteCommandResult]
}

/// Durable local idempotency ledger for the designated Mac. A command is never
/// executed twice, and an interrupted attempt becomes `uncertain`, not a retry.
@MainActor
public final class RemoteCommandExecutor {
    private struct Entry: Codable {
        var state: RemoteDeliveryState
    }
    private let executorID: UUID
    private let ledgerURL: URL
    private let bridge: any CodexBridging
    private var entries: [String: Entry]

    public init(executorID: UUID, ledgerURL: URL, bridge: any CodexBridging) throws {
        self.executorID = executorID
        self.ledgerURL = ledgerURL
        self.bridge = bridge
        if FileManager.default.fileExists(atPath: ledgerURL.path) {
            entries = try JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: ledgerURL))
        } else {
            entries = [:]
        }
        for key in entries.keys where entries[key]?.state == .processing {
            entries[key]?.state = .uncertain
        }
        try persist()
    }

    public func execute(_ command: RemoteCommand) async throws -> RemoteDeliveryState {
        guard command.executorID == executorID else { throw RemoteContinuationError.wrongExecutor }
        guard UUID(uuidString: command.threadID) != nil else { throw RemoteContinuationError.invalidThread }
        guard !command.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(command.images?.isEmpty ?? true) else {
            throw RemoteContinuationError.emptyMessage
        }
        let key = command.id.uuidString
        if let entry = entries[key] { return entry.state }
        entries[key] = Entry(state: .processing)
        do { try persist() } catch {
            entries.removeValue(forKey: key)
            throw error
        }
        var imagePaths: [String] = []
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowCueImages-\(command.id.uuidString)", isDirectory: true)
        do {
            if let images = command.images, !images.isEmpty {
                try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                for (index, encoded) in images.enumerated() {
                    guard let data = Data(base64Encoded: encoded) else { throw RemoteContinuationError.emptyMessage }
                    let url = tempDirectory.appendingPathComponent("\(index).jpg")
                    try data.write(to: url, options: .atomic)
                    imagePaths.append(url.path)
                }
            }
            let outcome = await bridge.queue(message: command.text, to: command.threadID, imagePaths: imagePaths)
            try? FileManager.default.removeItem(at: tempDirectory)
            let state: RemoteDeliveryState
            switch outcome {
            case .queued: state = .delivered
            case .failed: state = .failed
            case .unknown: state = .uncertain
            }
            entries[key] = Entry(state: state)
            do { try persist() } catch {
                entries[key] = Entry(state: .uncertain)
                throw error
            }
            return state
        } catch {
            try? FileManager.default.removeItem(at: tempDirectory)
            throw error
        }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: ledgerURL, options: .atomic)
    }
}

@MainActor
public final class RemoteContinuationService {
    private let executorID: UUID
    private let bridge: any CodexBridging
    private let transport: any RemoteContinuationTransport
    private let executor: RemoteCommandExecutor
    private let reader: CodexSessionReplyReader
    private var task: Task<Void, Never>?

    public init(
        executorID: UUID,
        bridge: any CodexBridging,
        transport: any RemoteContinuationTransport,
        ledgerURL: URL,
        sessionsDirectory: URL? = nil
    ) throws {
        self.executorID = executorID
        self.bridge = bridge
        self.transport = transport
        self.executor = try RemoteCommandExecutor(executorID: executorID, ledgerURL: ledgerURL, bridge: bridge)
        self.reader = CodexSessionReplyReader(sessionsDirectory: sessionsDirectory ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions"))
    }

    public func start() {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refreshThreads()
                await self?.processCommands()
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    public func refreshThreads() async {
        guard let contexts = try? await bridge.listThreads() else { return }
        let snapshots = contexts.map { context in
            RemoteThreadSnapshot(
                id: context.id,
                title: context.title,
                projectDirectory: context.projectDirectory,
                lastReply: reader.latestAssistantText(threadID: context.id) ?? "",
                updatedAt: context.recency,
                executorID: executorID
            )
        }
        try? await transport.publishThreads(snapshots)
    }

    public func processCommands() async {
        guard let commands = try? await transport.fetchCommands(executorID: executorID) else { return }
        for command in commands.sorted(by: { $0.createdAt < $1.createdAt }) {
            let state: RemoteDeliveryState
            do {
                state = try await executor.execute(command)
            } catch {
                continue
            }
            let reply = reader.latestAssistantText(threadID: command.threadID, after: command.createdAt)
            try? await transport.publishResult(RemoteCommandResult(id: command.id, state: state, reply: reply))
        }
    }
}


// MARK: - 通用 Agent 远程模型
//
// 手机端不依赖 Mac 内部的 AgentSession/AgentMessage，用这层 DTO 走网络。
// 新增一个 Agent 时，Mac 侧加适配器即可，手机端不需要改模型。

public struct RemoteAgentInfo: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    /// 该 Agent 的会话总数与涉及的项目目录数。
    public let sessionCount: Int
    public let projectCount: Int
    /// 是否能从手机发消息。
    public let canSend: Bool

    public init(id: String, displayName: String, sessionCount: Int, projectCount: Int, canSend: Bool) {
        self.id = id
        self.displayName = displayName
        self.sessionCount = sessionCount
        self.projectCount = projectCount
        self.canSend = canSend
    }
}

public struct RemoteAgentSession: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let agentID: String
    public let title: String
    public let projectPath: String?
    public let updatedAt: Date
    public let messageCount: Int?
    /// 正在执行的动作（DSH 有；其它 Agent 暂为 nil）。
    public let activity: String?

    public init(id: String, agentID: String, title: String, projectPath: String?, updatedAt: Date, messageCount: Int?, activity: String? = nil) {
        self.id = id
        self.agentID = agentID
        self.title = title
        self.projectPath = projectPath
        self.updatedAt = updatedAt
        self.messageCount = messageCount
        self.activity = activity
    }
}

public struct RemoteCodexImageMessage: Codable, Sendable {
    public static let maxImages = 4
    public static let batchMaxImages = 20
    public static let maxImageBytes = 320 * 1024
    public static let maxTextBytes = 8 * 1024
    public static let imageOnlyText = "Image attachment"

    public let text: String
    public let images: [Data]

    public init(text: String, images: [Data]) {
        self.text = text
        self.images = images
    }
}

public struct RemoteCodexImageBatch: Codable, Sendable {
    public let text: String
    public let count: Int

    public init(text: String, count: Int) {
        self.text = text
        self.count = count
    }

    @MainActor
    public static func uploadMissing(
        count: Int,
        status: () async throws -> [Int],
        put: (Int) async throws -> Void,
        retry: (Error) async throws -> Bool,
        onProgress: (Int) -> Void
    ) async throws {
        var mostUploaded = 0
        var failures = 0
        while true {
            try Task.checkCancellation()
            do {
                var uploaded = Set(try await status().filter { (0..<count).contains($0) })
                if uploaded.count > mostUploaded {
                    mostUploaded = uploaded.count
                    failures = 0
                }
                onProgress(uploaded.count)
                for index in 0..<count where !uploaded.contains(index) {
                    try Task.checkCancellation()
                    try await put(index)
                    uploaded.insert(index)
                    if uploaded.count > mostUploaded {
                        mostUploaded = uploaded.count
                        failures = 0
                    }
                    onProgress(uploaded.count)
                }
                return
            } catch {
                try Task.checkCancellation()
                failures += 1
                guard failures <= 3, try await retry(error) else { throw error }
            }
        }
    }
}

public struct PendingCodexImageBatch: Codable, Sendable {
    public enum Phase: String, Codable, Sendable { case uploading, submitted, acknowledged }

    public let batchID: String
    public let requestID: String
    public let text: String
    public let images: [Data]
    public let historyIDs: Set<String>
    public var phase: Phase

    public init(batchID: String, requestID: String, text: String, images: [Data],
                historyIDs: Set<String>, phase: Phase = .uploading) {
        self.batchID = batchID
        self.requestID = requestID
        self.text = text
        self.images = images
        self.historyIDs = historyIDs
        self.phase = phase
    }

    public static func load(from url: URL) throws -> Self? {
        do { return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)) }
        catch CocoaError.fileReadNoSuchFile { return nil }
    }

    public func save(to url: URL) throws {
        var folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #if os(iOS)
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try folder.setResourceValues(resources)
        let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        let options: Data.WritingOptions = .atomic
        #endif
        try JSONEncoder().encode(self).write(to: url, options: options)
    }
}

public struct AgentProgress: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case step, command, edit, tool, plan
    }

    public enum State: String, Codable, Hashable, Sendable {
        case inProgress, completed, failed, declined
    }

    public let kind: Kind
    public let state: State
    public let title: String?

    public init(kind: Kind, state: State, title: String? = nil) {
        self.kind = kind
        self.state = state
        self.title = title
    }
}

public struct RemoteAgentMessage: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let role: String
    public let text: String
    public let timestamp: Date?
    public let progress: AgentProgress?

    public init(id: String, role: String, text: String, timestamp: Date?, progress: AgentProgress? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.progress = progress
    }
}

public struct RemoteAgentMessagePage: Codable, Sendable {
    public let messages: [RemoteAgentMessage]
    public let hasOlder: Bool
    public let replacesHistory: Bool
    public let progressUpdates: [RemoteAgentMessage]?

    public init(messages: [RemoteAgentMessage], hasOlder: Bool, replacesHistory: Bool,
                progressUpdates: [RemoteAgentMessage]? = nil) {
        self.messages = messages
        self.hasOlder = hasOlder
        self.replacesHistory = replacesHistory
        self.progressUpdates = progressUpdates
    }

    static func window(in messages: [RemoteAgentMessage], before: String?, after: String?) -> Self {
        let pageSize = 20
        if let before {
            let end = messages.firstIndex(where: { $0.id == before }) ?? 0
            let start = max(0, end - pageSize)
            return .init(messages: Array(messages[start..<end]), hasOlder: start > 0, replacesHistory: false)
        }
        if let after, let index = messages.firstIndex(where: { $0.id == after }) {
            let updates = messages[...index].filter { $0.progress != nil }.suffix(pageSize)
            return .init(messages: Array(messages.dropFirst(index + 1).prefix(pageSize)),
                         hasOlder: false, replacesHistory: false,
                         progressUpdates: updates.isEmpty ? nil : Array(updates))
        }
        return .init(messages: Array(messages.suffix(pageSize)), hasOlder: messages.count > pageSize,
                     replacesHistory: true)
    }
}
