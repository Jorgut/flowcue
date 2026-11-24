import CryptoKit
import Network
import XCTest
@testable import CodexIdeaDockCore

/// 测试用最小客户端：握手 + 帧收发。
private final class StubClient {
    let connection: NWConnection
    private let queue = DispatchQueue(label: "test.stub.client")
    private(set) var received: [Data] = []

    init(port: UInt16, role: String, pair: String, onFrame: @escaping (Data) -> Void) {
        let parameters = NWParameters.tcp
        connection = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!,
            using: parameters
        )
        connection.start(queue: queue)
        sendFrame(Data(#"{"role":"\#(role)","pair":"\#(pair)"}"#.utf8), then: nil)
        receive(onFrame: onFrame)
    }

    func sendFrame(_ payload: Data, then completion: (() -> Void)?) {
        var header = UInt32(payload.count).bigEndian
        let data = Data(bytes: &header, count: 4) + payload
        connection.send(content: data, completion: .contentProcessed { _ in completion?() })
    }

    private func receive(onFrame: @escaping (Data) -> Void) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, _, _ in
            guard let self, let header, header.count == 4 else { return }
            let length = header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            guard length > 0, length < 1_048_576 else { return }
            self.connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { body, _, _, _ in
                guard let body, body.count == Int(length) else { return }
                self.received.append(body)
                onFrame(body)
                self.receive(onFrame: onFrame)
            }
        }
    }

    func cancel() { connection.cancel() }
}

final class RemoteRelayStubTests: XCTestCase {
    private var relay: RemoteRelayStub!

    override func setUpWithError() throws {
        relay = RemoteRelayStub()
        try relay.start()
        // 等 listener ready
        let deadline = Date().addingTimeInterval(3)
        while relay.port == 0 && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertGreaterThan(relay.port, 0, "中继没启动: \(relay.lastError ?? "unknown")")
    }

    override func tearDown() {
        relay?.stop()
        relay = nil
    }

    /// 手机发出的加密帧，Mac 能收到并解开。
    func testEncryptedFrameReachesMac() throws {
        let macKey = Curve25519.KeyAgreement.PrivateKey()
        let phoneKey = Curve25519.KeyAgreement.PrivateKey()
        let pairID = "pair-relay"
        var mac = try RemoteCryptoSession(
            localPrivate: macKey, peerPublic: phoneKey.publicKey,
            pairID: pairID, isInitiator: false
        )
        var phone = try RemoteCryptoSession(
            localPrivate: phoneKey, peerPublic: macKey.publicKey,
            pairID: pairID, isInitiator: true
        )

        let delivered = expectation(description: "mac receives")
        let macClient = StubClient(port: relay.port, role: "mac", pair: pairID) { frame in
            guard let envelope = try? JSONDecoder().decode(RemoteEnvelope.self, from: frame) else { return }
            if let plaintext = try? mac.open(envelope) {
                XCTAssertEqual(String(data: plaintext, encoding: .utf8), #"{"kind":"request"}"#)
                delivered.fulfill()
            }
        }

        let phoneClient = StubClient(port: relay.port, role: "ios", pair: pairID) { _ in }
        // 等两端握手完成
        Thread.sleep(forTimeInterval: 0.4)

        let payload = try phone.seal(Data(#"{"kind":"request"}"#.utf8))
        let frame = try JSONEncoder().encode(payload)
        phoneClient.sendFrame(frame, then: nil)

        wait(for: [delivered], timeout: 5)
        macClient.cancel()
        phoneClient.cancel()
    }

    /// Mac 不在线时，手机立刻收到 mac_offline，而不是挂住。
    func testMacOfflineReturnsError() throws {
        let replied = expectation(description: "mac_offline")
        let phoneClient = StubClient(port: relay.port, role: "ios", pair: "pair-offline") { frame in
            if String(data: frame, encoding: .utf8)?.contains("mac_offline") == true {
                replied.fulfill()
            }
        }
        Thread.sleep(forTimeInterval: 0.3)
        phoneClient.sendFrame(Data(#"{"seq":1}"#.utf8), then: nil)
        wait(for: [replied], timeout: 5)
        phoneClient.cancel()
    }

    /// 不同 pair 的帧不会串线。
    func testPairsAreIsolated() throws {
        let leaked = expectation(description: "no leak")
        leaked.isInverted = true

        let otherMac = StubClient(port: relay.port, role: "mac", pair: "pair-b") { _ in
            leaked.fulfill()
        }
        let phoneA = StubClient(port: relay.port, role: "ios", pair: "pair-a") { _ in }
        Thread.sleep(forTimeInterval: 0.4)

        phoneA.sendFrame(Data(#"{"seq":1}"#.utf8), then: nil)
        wait(for: [leaked], timeout: 1.0)
        otherMac.cancel()
        phoneA.cancel()
    }
}
