import CryptoKit
import Foundation

/// Remote 的中继信封。中继只看 `pair` / `seq` / `nonce` / 大小，其余不可读。
public struct RemoteEnvelope: Codable, Hashable, Sendable {
    public let v: Int
    public let pair: String
    public let seq: UInt64
    public let nonce: Data
    public let ciphertext: Data
    /// 每次建会话随机生成。对端重启后 seq 从 1 重新开始，
    /// 靠 epoch 变化来区分「新会话」和「重放旧的 seq=1」。
    public let epoch: String?

    public init(
        pair: String, seq: UInt64, nonce: Data, ciphertext: Data,
        v: Int = 1, epoch: String? = nil
    ) {
        self.v = v
        self.pair = pair
        self.seq = seq
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.epoch = epoch
    }
}

public enum RemoteCryptoError: Error, Sendable {
    case replay(seq: UInt64)
    case tooOld(seq: UInt64)
    case authenticationFailed
    case badNonce
}

/// 配对后两端各持一个 Session：mac→ios 与 ios→mac 用不同的对称密钥，
/// 各自维护单调递增的 seq，接收侧有 64 帧重放窗口。
public struct RemoteCryptoSession: Sendable {
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    public let pairID: String
    private var sendSeq: UInt64 = 0
    private var lastReceivedSeq: UInt64 = 0
    private let replayWindow: UInt64 = 64
    /// 本端会话标识；对端据此判断 seq 是否重新开始。
    private let sendEpoch = UUID().uuidString
    private var receiveEpoch: String?

    /// 由 X25519 共享密钥派生两个方向的密钥。
    /// - Parameter isInitiator: iPhone 为 true，Mac 为 false，决定收发方向互换。
    public init(
        localPrivate: Curve25519.KeyAgreement.PrivateKey,
        peerPublic: Curve25519.KeyAgreement.PublicKey,
        pairID: String,
        isInitiator: Bool
    ) throws {
        let shared = try localPrivate.sharedSecretFromKeyAgreement(with: peerPublic)
        let master = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(pairID.utf8),
            sharedInfo: Data("flowcue-remote-v1".utf8),
            outputByteCount: 32
        )
        let initiatorToResponder = Self.subkey(master, info: "ios2mac")
        let responderToInitiator = Self.subkey(master, info: "mac2ios")
        self.pairID = pairID
        if isInitiator {
            self.sendKey = initiatorToResponder
            self.receiveKey = responderToInitiator
        } else {
            self.sendKey = responderToInitiator
            self.receiveKey = initiatorToResponder
        }
    }

    private static func subkey(_ master: SymmetricKey, info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: master,
            info: Data(info.utf8),
            outputByteCount: 32
        )
    }

    // MARK: 发送

    public mutating func seal(_ plaintext: Data) throws -> RemoteEnvelope {
        sendSeq += 1
        let nonce = try ChaChaPoly.Nonce(data: Self.randomNonce())
        let box = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: nonce)
        return RemoteEnvelope(
            pair: pairID,
            seq: sendSeq,
            nonce: Data(box.nonce),
            ciphertext: box.ciphertext + box.tag,
            epoch: sendEpoch
        )
    }

    // MARK: 接收

    public mutating func open(_ envelope: RemoteEnvelope) throws -> Data {
        guard envelope.pair == pairID else { throw RemoteCryptoError.authenticationFailed }
        // 对端 App 重启后 sendSeq 会从 1 重新开始。用 epoch 区分新会话：
        // 只有 epoch 变化才清零序号；同一 epoch 内的重复 seq=1 仍按重放拒绝。
        if let epoch = envelope.epoch, epoch != receiveEpoch {
            receiveEpoch = epoch
            lastReceivedSeq = 0
        } else if envelope.epoch == nil, envelope.seq == 1, lastReceivedSeq > 1 {
            // 兼容没有 epoch 的旧客户端。
            lastReceivedSeq = 0
        }
        if envelope.seq <= lastReceivedSeq {
            // 允许窗口内乱序，超窗或重复一律拒绝
            throw envelope.seq + replayWindow < lastReceivedSeq
                ? RemoteCryptoError.tooOld(seq: envelope.seq)
                : RemoteCryptoError.replay(seq: envelope.seq)
        }
        guard envelope.ciphertext.count > 16 else { throw RemoteCryptoError.authenticationFailed }
        let ciphertext = envelope.ciphertext.dropLast(16)
        let tag = envelope.ciphertext.suffix(16)
        let nonce: ChaChaPoly.Nonce
        do {
            nonce = try ChaChaPoly.Nonce(data: envelope.nonce)
        } catch {
            throw RemoteCryptoError.badNonce
        }
        let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let plaintext: Data
        do {
            plaintext = try ChaChaPoly.open(box, using: receiveKey)
        } catch {
            throw RemoteCryptoError.authenticationFailed
        }
        lastReceivedSeq = envelope.seq
        return plaintext
    }

    private static func randomNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: 12)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }
}
