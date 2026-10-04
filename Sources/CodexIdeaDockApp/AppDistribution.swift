#if SWIFT_PACKAGE
import CodexIdeaDockCore
#endif

enum AppDistribution {
    #if REROUTE_APP_STORE
    static let supportsDirectQueue = false
    #else
    static let supportsDirectQueue = true
    #endif
}

#if REROUTE_APP_STORE
struct AppStoreCodexBridge: CodexBridging {
    func listThreads() async throws -> [WorkContextItem] {
        []
    }

    func queue(message: String, to threadID: String) async -> QueueDeliveryOutcome {
        .failed(exitCode: nil, message: "Codex CLI is unavailable.")
    }
}
#endif
