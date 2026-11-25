import CryptoKit
import XCTest
@testable import CodexIdeaDockCore

/// 通过手机会用的同一套 HTTP 接口走一遍配对，确认端到端可用。
private struct SilentBridge2: CodexBridging {
    func listThreads() async throws -> [WorkContextItem] { [] }
    func queue(message: String, to threadID: String) async -> QueueDeliveryOutcome {
        .failed(exitCode: nil, message: "unused")
    }
}

@MainActor
final class RemotePairingAPITests: XCTestCase {
    private var server: LANRemoteServer!
    private let code = "246810"
    private var auth: [String: String] { ["authorization": "Bearer \(code)"] }

    override func setUpWithError() throws {
        let ledger = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowcue-pair-\(UUID().uuidString).json")
        server = try LANRemoteServer(
            executorID: UUID(),
            pairingCode: code,
            bridge: SilentBridge2(),
            ledgerURL: ledger,
            pairingStoreDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("flowcue-pairs-\(UUID().uuidString)")
        )
    }

    private struct BeginPayload: Decodable { let code: String; let macID: String; let publicKey: String }
    private struct PairPayload: Decodable { let pairID: String }
    private struct StatusPayload: Decodable { let status: String }

    func testFullPairingFlowOverHTTP() async throws {
        // 1. Mac 生成配对码
        let begin = await server.dispatchRemote(method: "POST", path: "/v1/remote/pair/begin", headers: auth)
        XCTAssertEqual(begin.status, 200)
        let payload = try JSONDecoder().decode(BeginPayload.self, from: begin.body)
        XCTAssertEqual(payload.code.count, 6)

        // 2. 手机提交自己的公钥
        let phoneKey = Curve25519.KeyAgreement.PrivateKey()
        let requestBody = try JSONEncoder().encode([
            "code": payload.code,
            "phonePublicKey": phoneKey.publicKey.rawRepresentation.base64EncodedString()
        ])
        let requested = await server.dispatchRemote(
            method: "POST", path: "/v1/remote/pair/request",
            headers: auth, body: requestBody
        )
        XCTAssertEqual(requested.status, 200)
        let pair = try JSONDecoder().decode(PairPayload.self, from: requested.body)

        // 3. 等待批准
        let pending = await server.dispatchRemote(
            method: "GET", path: "/v1/remote/pair/status/\(pair.pairID)", headers: auth
        )
        XCTAssertEqual(try JSONDecoder().decode(StatusPayload.self, from: pending.body).status, "pending")

        // 4. Mac 批准
        let approved = await server.dispatchRemote(
            method: "POST", path: "/v1/remote/pair/approve",
            headers: auth, body: try JSONEncoder().encode(["pairID": pair.pairID])
        )
        XCTAssertEqual(approved.status, 200)

        let status = await server.dispatchRemote(
            method: "GET", path: "/v1/remote/pair/status/\(pair.pairID)", headers: auth
        )
        XCTAssertEqual(try JSONDecoder().decode(StatusPayload.self, from: status.body).status, "approved")

        // 5. 撤销后不再批准
        _ = await server.dispatchRemote(
            method: "POST", path: "/v1/remote/pair/revoke",
            headers: auth, body: try JSONEncoder().encode(["pairID": pair.pairID])
        )
        let revoked = await server.dispatchRemote(
            method: "GET", path: "/v1/remote/pair/status/\(pair.pairID)", headers: auth
        )
        XCTAssertEqual(try JSONDecoder().decode(StatusPayload.self, from: revoked.body).status, "revoked")
    }

    func testWrongCodeFailsOverHTTP() async throws {
        _ = await server.dispatchRemote(method: "POST", path: "/v1/remote/pair/begin", headers: auth)
        let phoneKey = Curve25519.KeyAgreement.PrivateKey()
        let body = try JSONEncoder().encode([
            "code": "000000",
            "phonePublicKey": phoneKey.publicKey.rawRepresentation.base64EncodedString()
        ])
        let result = await server.dispatchRemote(
            method: "POST", path: "/v1/remote/pair/request", headers: auth, body: body
        )
        XCTAssertEqual(result.status, 409, "错误的配对码必须被拒绝")
    }
}
