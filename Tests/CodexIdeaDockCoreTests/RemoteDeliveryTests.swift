import Foundation
import XCTest
@testable import CodexIdeaDockCore

@MainActor
final class RemoteDeliveryTests: XCTestCase {
    func testOnlyPairedPhoneAndDesignatedExecutorCanDeliver() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = UUID(), phone = UUID()
        let bridge = DeliveryTestBridge()
        let gate = try RemoteDeliveryGate(executorID: executor, ledgerURL: directory.appendingPathComponent("delivery.json"), bridge: bridge)
        let request = RemoteDeliveryRequest(phoneID: phone, executorID: executor, targetThreadID: UUID(), text: "synthetic idea")
        do {
            _ = try await gate.deliver(request, pairedPhones: [])
            XCTFail("Unpaired request must fail")
        } catch RemoteDeliveryError.unpairedDevice {}
        let wrong = RemoteDeliveryRequest(phoneID: phone, executorID: UUID(), targetThreadID: UUID(), text: "synthetic idea")
        do {
            _ = try await gate.deliver(wrong, pairedPhones: [phone])
            XCTFail("Wrong executor must fail")
        } catch RemoteDeliveryError.wrongExecutor {}
        let calls = await bridge.calls
        XCTAssertEqual(calls, 0)
        let first = try await gate.deliver(request, pairedPhones: [phone])
        let second = try await gate.deliver(request, pairedPhones: [phone])
        XCTAssertEqual(first, .delivered)
        XCTAssertEqual(second, .delivered)
        let finalCalls = await bridge.calls
        XCTAssertEqual(finalCalls, 1)
    }

    func testUncertainRequestIsNotRetriedAfterRestartOrWithChangedContent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("delivery.json")
        let executor = UUID(), phone = UUID()
        let bridge = DeliveryTestBridge(outcome: .unknown(message: "uncertain"))
        let request = RemoteDeliveryRequest(phoneID: phone, executorID: executor, targetThreadID: UUID(), text: "private synthetic text")
        let gate = try RemoteDeliveryGate(executorID: executor, ledgerURL: url, bridge: bridge)
        let result = try await gate.deliver(request, pairedPhones: [phone])
        XCTAssertEqual(result, .uncertain)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains(request.text))
        let restarted = try RemoteDeliveryGate(executorID: executor, ledgerURL: url, bridge: bridge)
        let retry = try await restarted.deliver(request, pairedPhones: [phone])
        XCTAssertEqual(retry, .uncertain)
        let changed = RemoteDeliveryRequest(id: request.id, phoneID: phone, executorID: executor, targetThreadID: request.targetThreadID, text: "changed")
        do {
            _ = try await restarted.deliver(changed, pairedPhones: [phone])
            XCTFail("Reused ID with changed payload must fail")
        } catch RemoteDeliveryError.conflictingRequest {}
        let calls = await bridge.calls
        XCTAssertEqual(calls, 1)
    }
}

private actor DeliveryTestBridge: CodexBridging {
    var calls = 0
    let outcome: QueueDeliveryOutcome
    init(outcome: QueueDeliveryOutcome = .queued(exitCode: 0)) { self.outcome = outcome }
    func listThreads() async throws -> [WorkContextItem] { [] }
    func queue(message: String, to threadID: String) async -> QueueDeliveryOutcome {
        calls += 1
        return outcome
    }
}
