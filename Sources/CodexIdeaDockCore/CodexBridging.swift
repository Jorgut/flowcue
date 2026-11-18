public protocol CodexBridging: Sendable {
    func listThreads() async throws -> [WorkContextItem]
    func queue(message: String, to threadID: String) async -> QueueDeliveryOutcome
}

public extension CodexBridging {
    /// Bridges that do not understand attachments keep their text-only behavior.
    func queue(message: String, to threadID: String, imagePaths: [String]) async -> QueueDeliveryOutcome {
        await queue(message: message, to: threadID)
    }
}
