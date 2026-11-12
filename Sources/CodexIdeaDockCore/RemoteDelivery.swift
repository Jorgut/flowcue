import Foundation
import CryptoKit

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
    public let createdAt: Date

    public init(id: UUID = UUID(), phoneID: UUID, executorID: UUID, threadID: String, text: String, createdAt: Date = Date()) {
        self.id = id
        self.phoneID = phoneID
        self.executorID = executorID
        self.threadID = threadID
        self.text = text
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

    public init(sessionId: String, text: String) {
        self.sessionId = sessionId
        self.text = text
    }
}

public struct DSHSessionSnapshot: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let projectDirectory: String
    public let updatedAt: Date

    public init(id: String, title: String, projectDirectory: String, updatedAt: Date) {
        self.id = id
        self.title = title
        self.projectDirectory = projectDirectory
        self.updatedAt = updatedAt
    }
}

public struct RemoteConversationMessage: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let role: String
    public let text: String
    public let timestamp: Date?

    public init(id: String, role: String, text: String, timestamp: Date? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
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
            guard !text.isEmpty else { continue }
            // Codex injects synthetic context/page markers as user messages.
            if role == "user", text.hasPrefix("<"), text.hasSuffix(">") { continue }
            let timestamp = (object["timestamp"] as? String).flatMap(Self.isoDate)
            result.append(RemoteConversationMessage(
                id: "\(result.count)-\(role)",
                role: role,
                text: String(text.prefix(20_000)),
                timestamp: timestamp
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
        guard !command.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteContinuationError.emptyMessage
        }
        let key = command.id.uuidString
        if let entry = entries[key] { return entry.state }
        entries[key] = Entry(state: .processing)
        do { try persist() } catch {
            entries.removeValue(forKey: key)
            throw error
        }
        let outcome = await bridge.queue(message: command.text, to: command.threadID)
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
