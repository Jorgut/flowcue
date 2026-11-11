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
