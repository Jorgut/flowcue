import XCTest
@testable import CodexIdeaDockCore

final class RemoteReaderTests: XCTestCase {
    func testReadsLastAssistantTextFromRollout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let thread = UUID().uuidString.lowercased()
        let file = root.appendingPathComponent("rollout-\(thread).jsonl")
        let lines = [
            #"{"timestamp":"2026-11-12T01:00:00.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"older answer"}]}}"#,
            #"{"timestamp":"2026-11-12T01:05:00.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"latest answer"}]}}"#
        ].joined(separator: "\n")
        try lines.write(to: file, atomically: true, encoding: .utf8)
        let reader = CodexSessionReplyReader(sessionsDirectory: root)
        XCTAssertEqual(reader.latestAssistantText(threadID: thread), "latest answer")
        let after = ISO8601DateFormatter().date(from: "2026-11-12T01:02:00Z")!
        XCTAssertEqual(reader.latestAssistantText(threadID: thread, after: after), "latest answer")
        XCTAssertNil(reader.latestAssistantText(threadID: UUID().uuidString))
    }
}

private final class CountingBridge: CodexBridging, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var queueCount = 0
    func listThreads() async throws -> [WorkContextItem] { [] }
    func queue(message: String, to threadID: String) async -> QueueDeliveryOutcome {
        increment()
        return .queued(exitCode: 0)
    }

    private func increment() {
        lock.lock()
        queueCount += 1
        lock.unlock()
    }
}

@MainActor
final class RemoteCommandExecutorTests: XCTestCase {
    func testRetryDoesNotExecuteTwice() async throws {
        let bridge = CountingBridge()
        let ledger = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("ledger.json")
        let executorID = UUID()
        let executor = try RemoteCommandExecutor(executorID: executorID, ledgerURL: ledger, bridge: bridge)
        let command = RemoteCommand(phoneID: UUID(), executorID: executorID, threadID: UUID().uuidString, text: "continue")
        let first = try await executor.execute(command)
        let second = try await executor.execute(command)
        XCTAssertEqual(first, .delivered)
        XCTAssertEqual(second, .delivered)
        XCTAssertEqual(bridge.queueCount, 1)
    }
}
