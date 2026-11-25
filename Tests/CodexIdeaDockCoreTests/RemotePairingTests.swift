import CryptoKit
import XCTest
@testable import CodexIdeaDockCore

private final class Clock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

final class RemotePairingTests: XCTestCase {
    private var clock: Clock!
    private var mac: RemotePairingManager!
    private var phoneKey: Curve25519.KeyAgreement.PrivateKey!
    private var storeDirectory: URL!

    override func setUp() {
        clock = Clock()
        // 每个用例独立目录：以前用默认 ~/.flowcue，测试批准会写进真实
        // remote-pairs.json，设置页因此堆出十几条匿名配对。
        storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowcue-pair-tests-\(UUID().uuidString)")
        mac = RemotePairingManager(
            now: { [clock] in clock!.now },
            storeDirectory: storeDirectory
        )
        phoneKey = Curve25519.KeyAgreement.PrivateKey()
    }

    override func tearDown() {
        if let storeDirectory {
            try? FileManager.default.removeItem(at: storeDirectory)
        }
    }

    private func phoneSession(pairID: String) async throws -> RemoteCryptoSession {
        let macPublicKey = await mac.publicKey
        let macPublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: macPublicKey)
        return try RemoteCryptoSession(
            localPrivate: phoneKey, peerPublic: macPublic,
            pairID: pairID, isInitiator: true
        )
    }

    func testCorrectCodeApprovesAndBothSidesAgree() async throws {
        let code = await mac.beginPairing()
        let pairID = try await mac.request(code: code, phonePublicKey: phoneKey.publicKey.rawRepresentation)
        let approved = try await mac.approve(pairID: pairID)
        XCTAssertTrue(approved.approved)

        var phone = try await phoneSession(pairID: pairID)
        let macSide = await mac.session(for: pairID)
        var macSession = try XCTUnwrap(macSide)

        let envelope = try phone.seal(Data(#"{"kind":"request"}"#.utf8))
        let plaintext = try macSession.open(envelope)
        XCTAssertEqual(String(decoding: plaintext, as: UTF8.self), #"{"kind":"request"}"#)

        let reply = try macSession.seal(Data(#"{"status":200}"#.utf8))
        XCTAssertEqual(String(decoding: try phone.open(reply), as: UTF8.self), #"{"status":200}"#)
    }

    /// 响应必须用存储中的会话逐条递增 seq。
    /// 用 `session(for:)` 的副本会导致每条响应都是 seq=1，手机只认第一条。
    func testStoredSessionAdvancesSequenceForEveryResponse() async throws {
        let code = await mac.beginPairing()
        let pairID = try await mac.request(code: code, phonePublicKey: phoneKey.publicKey.rawRepresentation)
        _ = try await mac.approve(pairID: pairID)
        var phone = try await phoneSession(pairID: pairID)

        let first = try await mac.sealEnvelope(pairID: pairID, plaintext: Data("one".utf8))
        let second = try await mac.sealEnvelope(pairID: pairID, plaintext: Data("two".utf8))
        XCTAssertEqual(first.seq, 1)
        XCTAssertEqual(second.seq, 2)
        XCTAssertEqual(try phone.open(first), Data("one".utf8))
        XCTAssertEqual(try phone.open(second), Data("two".utf8))

        // 反向也一样：Mac 收到的 seq 要写回存储，重复帧才会被拒绝。
        let phoneFirst = try phone.seal(Data("a".utf8))
        let phoneSecond = try phone.seal(Data("b".utf8))
        let macFirst = try await mac.openEnvelope(phoneFirst)
        let macSecond = try await mac.openEnvelope(phoneSecond)
        XCTAssertEqual(macFirst, Data("a".utf8))
        XCTAssertEqual(macSecond, Data("b".utf8))
        do {
            _ = try await mac.openEnvelope(phoneFirst)
            XCTFail("重复帧被接受了")
        } catch {
            // expected
        }
    }

    func testWrongCodeIsRejectedAndLocksAfterFiveAttempts() async throws {
        let code = await mac.beginPairing()
        for _ in 0..<5 {
            do {
                _ = try await mac.request(code: "000000", phonePublicKey: phoneKey.publicKey.rawRepresentation)
                XCTFail("错误验证码不应通过")
            } catch let error as RemotePairingManager.PairingError {
                XCTAssertEqual(error, .invalidCode)
            }
        }
        do {
            _ = try await mac.request(code: code, phonePublicKey: phoneKey.publicKey.rawRepresentation)
            XCTFail("锁定后正确码也不该通过")
        } catch let error as RemotePairingManager.PairingError {
            XCTAssertEqual(error, .locked)
        }
    }

    func testExpiredCodeIsRejected() async throws {
        let code = await mac.beginPairing()
        clock.advance(301)
        do {
            _ = try await mac.request(code: code, phonePublicKey: phoneKey.publicKey.rawRepresentation)
            XCTFail("过期码不该通过")
        } catch let error as RemotePairingManager.PairingError {
            XCTAssertEqual(error, .expired)
        }
    }

    func testCodeIsSingleUse() async throws {
        let code = await mac.beginPairing()
        _ = try await mac.request(code: code, phonePublicKey: phoneKey.publicKey.rawRepresentation)
        do {
            _ = try await mac.request(code: code, phonePublicKey: phoneKey.publicKey.rawRepresentation)
            XCTFail("同一个码不能用两次")
        } catch let error as RemotePairingManager.PairingError {
            XCTAssertEqual(error, .expired)
        }
    }

    func testRevokedPairCannotReconnect() async throws {
        let code = await mac.beginPairing()
        let pairID = try await mac.request(code: code, phonePublicKey: phoneKey.publicKey.rawRepresentation)
        _ = try await mac.approve(pairID: pairID)
        await mac.revoke(pairID: pairID)

        let session = await mac.session(for: pairID)
        XCTAssertNil(session, "撤销后不该再有会话")
        let revoked = await mac.isRevoked(pairID)
        XCTAssertTrue(revoked)
    }

    func testDeniedPairHasNoSession() async throws {
        let code = await mac.beginPairing()
        let pairID = try await mac.request(code: code, phonePublicKey: phoneKey.publicKey.rawRepresentation)
        await mac.deny(pairID: pairID)
        let session = await mac.session(for: pairID)
        XCTAssertNil(session)
    }

    /// 同一台手机（phoneID 相同）重新配对时，旧记录必须被替换，
    /// 不能让设置页每次重装/重配都多一条。
    func testSamePhoneIDReplacesPreviousPair() async throws {
        let firstCode = await mac.beginPairing()
        let firstPair = try await mac.request(
            code: firstCode,
            phonePublicKey: phoneKey.publicKey.rawRepresentation,
            phoneID: "install-1",
            phoneName: "iPhone 17 Pro"
        )
        let first = try await mac.approve(pairID: firstPair)
        XCTAssertEqual(first.replacedPairIDs, [])

        let secondKey = Curve25519.KeyAgreement.PrivateKey()
        let secondCode = await mac.beginPairing()
        let secondPair = try await mac.request(
            code: secondCode,
            phonePublicKey: secondKey.publicKey.rawRepresentation,
            phoneID: "install-1",
            phoneName: "iPhone 17 Pro"
        )
        let second = try await mac.approve(pairID: secondPair)
        XCTAssertEqual(second.replacedPairIDs, [firstPair])
        let active = await mac.activePairIDs
        XCTAssertEqual(active, [secondPair])
        let phones = await mac.pairedPhoneInfos
        XCTAssertEqual(phones.first?.phoneName, "iPhone 17 Pro")
    }

    func testRevokeAllClearsPairedPhones() async throws {
        var pairIDs: [String] = []
        for index in 0..<3 {
            let code = await mac.beginPairing()
            let pairID = try await mac.request(
                code: code,
                phonePublicKey: phoneKey.publicKey.rawRepresentation,
                phoneID: "install-\(index)"
            )
            _ = try await mac.approve(pairID: pairID)
            pairIDs.append(pairID)
        }
        let removed = await mac.revokeAll()
        XCTAssertEqual(Set(removed), Set(pairIDs))
        let remaining = await mac.approvedCount
        XCTAssertEqual(remaining, 0)
    }
}

/// Mac 重启后已批准的配对必须还在，否则手机每次都要重新配对。
final class RemotePairingPersistenceTests: XCTestCase {
    func testApprovedPairSurvivesRestart() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowcue-pairs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let phoneKey = Curve25519.KeyAgreement.PrivateKey()
        var pairID = ""
        var macPublicBefore = Data()

        // 第一次启动：配对 + 批准
        do {
            let mac = RemotePairingManager(storeDirectory: dir)
            macPublicBefore = await mac.publicKey
            let code = await mac.beginPairing()
            pairID = try await mac.request(code: code, phonePublicKey: phoneKey.publicKey.rawRepresentation)
            _ = try await mac.approve(pairID: pairID)
        }

        // 模拟重启：新实例，同一目录
        let restarted = RemotePairingManager(storeDirectory: dir)
        let macPublicAfter = await restarted.publicKey
        XCTAssertEqual(macPublicBefore, macPublicAfter, "身份密钥应该持久化")

        let session = await restarted.session(for: pairID)
        var macSession = try XCTUnwrap(session, "已批准的配对应该在重启后仍可用")

        // 手机侧用同一个 pairID 发一条，Mac 能解开
        let phone = try RemoteCryptoSession(
            localPrivate: phoneKey, peerPublic: Curve25519.KeyAgreement.PublicKey(rawRepresentation: macPublicAfter),
            pairID: pairID, isInitiator: true
        )
        var sender = phone
        let envelope = try sender.seal(Data("still-paired".utf8))
        XCTAssertEqual(String(decoding: try macSession.open(envelope), as: UTF8.self), "still-paired")
    }
}
