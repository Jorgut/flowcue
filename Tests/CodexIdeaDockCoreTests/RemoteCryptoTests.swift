import CryptoKit
import XCTest
@testable import CodexIdeaDockCore

final class RemoteCryptoTests: XCTestCase {
    private func makeSessions() throws -> (iphone: RemoteCryptoSession, mac: RemoteCryptoSession) {
        let macKey = Curve25519.KeyAgreement.PrivateKey()
        let phoneKey = Curve25519.KeyAgreement.PrivateKey()
        let pairID = "pair-test"
        let mac = try RemoteCryptoSession(
            localPrivate: macKey, peerPublic: phoneKey.publicKey,
            pairID: pairID, isInitiator: false
        )
        let phone = try RemoteCryptoSession(
            localPrivate: phoneKey, peerPublic: macKey.publicKey,
            pairID: pairID, isInitiator: true
        )
        return (phone, mac)
    }

    func testRoundTripBothDirections() throws {
        var (phone, mac) = try makeSessions()
        let request = Data(#"{"kind":"request","path":"/v1/agents"}"#.utf8)

        let envelope = try phone.seal(request)
        XCTAssertEqual(try mac.open(envelope), request)

        let response = Data(#"{"kind":"response","status":200}"#.utf8)
        let reply = try mac.seal(response)
        XCTAssertEqual(try phone.open(reply), response)
    }

    func testReplayIsRejected() throws {
        var (phone, mac) = try makeSessions()
        let envelope = try phone.seal(Data("hello".utf8))
        _ = try mac.open(envelope)
        XCTAssertThrowsError(try mac.open(envelope)) { error in
            guard case RemoteCryptoError.replay = error else {
                return XCTFail("expected replay, got \(error)")
            }
        }
    }

    func testTamperedCiphertextIsRejected() throws {
        var (phone, mac) = try makeSessions()
        let sealed = try phone.seal(Data("secret".utf8))
        var bytes = [UInt8](sealed.ciphertext)
        bytes[0] ^= 0xFF
        let tampered = RemoteEnvelope(
            pair: sealed.pair, seq: sealed.seq,
            nonce: sealed.nonce, ciphertext: Data(bytes)
        )
        XCTAssertThrowsError(try mac.open(tampered)) { error in
            guard case RemoteCryptoError.authenticationFailed = error else {
                return XCTFail("expected auth failure, got \(error)")
            }
        }
    }

    /// 用另一对密钥解同一帧，也必须失败。
    func testWrongKeyIsRejected() throws {
        var (phone, _) = try makeSessions()
        var (_, otherMac) = try makeSessions()
        let sealed = try phone.seal(Data("secret".utf8))
        XCTAssertThrowsError(try otherMac.open(sealed)) { error in
            guard case RemoteCryptoError.authenticationFailed = error else {
                return XCTFail("expected auth failure, got \(error)")
            }
        }
    }

    func testWrongPairIDIsRejected() throws {
        var (phone, mac) = try makeSessions()
        let sealed = try phone.seal(Data("x".utf8))
        let mismatched = RemoteEnvelope(pair: "other", seq: sealed.seq, nonce: sealed.nonce, ciphertext: sealed.ciphertext)
        XCTAssertThrowsError(try mac.open(mismatched))
    }

    func testEnvelopeCarriesNoPlaintext() throws {
        var (phone, _) = try makeSessions()
        let plaintext = Data("read the API key in .env".utf8)
        let envelope = try phone.seal(plaintext)
        XCTAssertFalse(envelope.ciphertext.contains(Data("API key".utf8)))
        XCTAssertNotEqual(envelope.ciphertext, plaintext)
    }

    /// 对端进程重启后 seq 从 1 重新开始：接收侧必须接受，否则整轮请求
    /// 都会被当成重放丢掉，手机界面表现为「一直加载」。
    func testPeerRestartSequenceResetIsAccepted() throws {
        let macKey = Curve25519.KeyAgreement.PrivateKey()
        let phoneKey = Curve25519.KeyAgreement.PrivateKey()
        let pairID = "pair-restart"
        var mac = try RemoteCryptoSession(
            localPrivate: macKey, peerPublic: phoneKey.publicKey,
            pairID: pairID, isInitiator: false
        )

        var firstRun = try RemoteCryptoSession(
            localPrivate: phoneKey, peerPublic: macKey.publicKey,
            pairID: pairID, isInitiator: true
        )
        for index in 0..<3 {
            let payload = Data("before-restart-\(index)".utf8)
            XCTAssertEqual(try mac.open(try firstRun.seal(payload)), payload)
        }

        // 模拟手机 App 重启：同一对密钥、新的会话（sendSeq 归零）。
        var secondRun = try RemoteCryptoSession(
            localPrivate: phoneKey, peerPublic: macKey.publicKey,
            pairID: pairID, isInitiator: true
        )
        let afterRestart = Data("after-restart".utf8)
        XCTAssertEqual(try mac.open(try secondRun.seal(afterRestart)), afterRestart)
    }
}
