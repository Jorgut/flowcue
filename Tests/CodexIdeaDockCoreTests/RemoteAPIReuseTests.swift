import XCTest
@testable import CodexIdeaDockCore

/// 中继隧道必须复用 LAN 的路由，而不是另起一套端点。
private struct SilentBridge: CodexBridging {
    func listThreads() async throws -> [WorkContextItem] { [] }
    func queue(message: String, to threadID: String) async -> QueueDeliveryOutcome {
        .failed(exitCode: nil, message: "unused")
    }
}

@MainActor
final class RemoteAPIReuseTests: XCTestCase {
    private var server: LANRemoteServer!
    private let code = "135790"

    override func setUpWithError() throws {
        let ledger = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowcue-api-\(UUID().uuidString).json")
        server = try LANRemoteServer(
            executorID: UUID(),
            pairingCode: code,
            bridge: SilentBridge(),
            ledgerURL: ledger,
            pairingStoreDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("flowcue-pairs-api-\(UUID().uuidString)")
        )
    }

    func testPingWorksWithoutAuth() async {
        let result = await server.dispatchRemote(method: "GET", path: "/v1/ping", headers: [:])
        XCTAssertEqual(result.status, 200)
    }

    func testAgentHistoryWindowsUseMessageAnchors() {
        let messages = (0..<55).map { RemoteAgentMessage(id: String($0), role: "user", text: "test", timestamp: nil) }
        let latest = RemoteAgentMessagePage.window(in: messages, before: nil, after: nil)
        XCTAssertEqual(latest.messages.map(\.id), (35..<55).map(String.init))
        XCTAssertTrue(latest.hasOlder)
        XCTAssertTrue(latest.replacesHistory)

        let older = RemoteAgentMessagePage.window(in: messages, before: "35", after: nil)
        XCTAssertEqual(older.messages.map(\.id), (15..<35).map(String.init))
        XCTAssertFalse(older.replacesHistory)

        let newer = RemoteAgentMessagePage.window(in: messages, before: nil, after: "53")
        XCTAssertEqual(newer.messages.map(\.id), ["54"])
        XCTAssertFalse(newer.replacesHistory)

        let expired = RemoteAgentMessagePage.window(in: messages, before: nil, after: "expired")
        XCTAssertEqual(expired.messages, latest.messages)
        XCTAssertTrue(expired.replacesHistory)
    }

    func testRunReadOnlyHTTPSDeviceFixture() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let root = env["FLOWCUE_TEST_HTTPS_FIXTURE"],
              let address = env["FLOWCUE_TEST_HTTPS_URL"], let destination = URL(string: address),
              env["FLOWCUE_TEST_HTTPS_READ_ONLY"] == "1" else {
            throw XCTSkip("Opt-in read-only iPhone HTTPS fixture")
        }
        let stub = URL(fileURLWithPath: root, isDirectory: true)
        let fixture = try LANRemoteServer(
            executorID: UUID(),
            pairingCode: code,
            bridge: SilentBridge(),
            ledgerURL: stub.appendingPathComponent("ledger.json"),
            sessionsDirectory: stub.appendingPathComponent("sessions"),
            pairingStoreDirectory: stub.appendingPathComponent("pairs")
        )
        let relay = RemoteRelayClient(relayURL: destination, macID: UUID().uuidString, server: fixture)
        relay.start()
        defer { relay.stop() }
        print("HTTPS iPhone fixture ready")
        let seconds = min(300, max(30, Int(env["FLOWCUE_TEST_HTTPS_FIXTURE_SECONDS"] ?? "") ?? 90))
        try await Task.sleep(for: .seconds(seconds))
    }

    func testProtectedRouteRejectsWithoutToken() async {
        let result = await server.dispatchRemote(method: "GET", path: "/v1/agents", headers: [:])
        XCTAssertEqual(result.status, 401)
    }

    func testExternalApprovalCardApprovesOnceAndRejectsConflictingDecision() async throws {
        let headers = ["authorization": "Bearer \(code)"]
        let created = await server.dispatchRemote(
            method: "POST", path: "/v1/approvals", headers: headers,
            body: Data(#"{"agent":"claude","sessionId":"qa-session","title":"QA approval"}"#.utf8)
        )
        XCTAssertEqual(created.status, 200)
        let id = try XCTUnwrap(JSONDecoder().decode([String: String].self, from: created.body)["id"])
        let list = await server.dispatchRemote(method: "GET", path: "/v1/dsh/approvals", headers: headers)
        let approval = try XCTUnwrap(JSONDecoder().decode(DSHRemoteApprovalsResponse.self, from: list.body)
            .pending.first { $0.id == id })
        XCTAssertEqual(approval.agentID, "claude")
        XCTAssertEqual(approval.sessionId, "qa-session")

        for (decision, expected) in [("allowed-once", 200), ("allowed-once", 200), ("rejected", 409)] {
            let result = await server.dispatchRemote(
                method: "POST", path: "/v1/dsh/decide", headers: headers,
                body: try JSONEncoder().encode(DSHRemoteDecision(id: id, decision: decision))
            )
            XCTAssertEqual(result.status, expected)
        }
        let result = await server.dispatchRemote(method: "GET", path: "/v1/approvals/\(id)", headers: headers)
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: result.body)["status"], "approved")
    }

    func testProtectedRouteWorksWithToken() async {
        let result = await server.dispatchRemote(
            method: "GET", path: "/v1/ping",
            headers: ["authorization": "Bearer \(code)"]
        )
        XCTAssertEqual(result.status, 200)
        XCTAssertFalse(result.body.isEmpty)
    }

    func testUnknownRouteIs404() async {
        let result = await server.dispatchRemote(
            method: "GET", path: "/v1/does-not-exist",
            headers: ["authorization": "Bearer \(code)"]
        )
        XCTAssertEqual(result.status, 404)
    }
}
