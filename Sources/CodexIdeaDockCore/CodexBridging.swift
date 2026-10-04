public protocol CodexBridging: Sendable {
    func listThreads() async throws -> [WorkContextItem]
    func queue(message: String, to threadID: String) async -> QueueDeliveryOutcome
}
