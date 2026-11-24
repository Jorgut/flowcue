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
            ledgerURL: ledger
        )
    }

    func testPingWorksWithoutAuth() async {
        let result = await server.dispatchRemote(method: "GET", path: "/v1/ping", headers: [:])
        XCTAssertEqual(result.status, 200)
    }

    func testProtectedRouteRejectsWithoutToken() async {
        let result = await server.dispatchRemote(method: "GET", path: "/v1/agents", headers: [:])
        XCTAssertEqual(result.status, 401)
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
