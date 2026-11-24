import CryptoKit
import Foundation

/// Mac 端的配对状态机：一次性 6 位码、5 分钟有效、最多 5 次尝试，
/// 批准后两端各自用 X25519 派生同一组会话密钥。
///
/// 中继只转发公钥和 pair 标识，永远拿不到共享密钥。
public actor RemotePairingManager {
    public enum PairingError: Error, Sendable, Equatable {
        case invalidCode
        case expired
        case locked
        case unknownPair
        case notApproved
        case alreadyRevoked
    }

    public struct PendingPair: Sendable {
        public let pairID: String
        public let phonePublicKey: Data
        public let createdAt: Date
        public var approved: Bool
    }

    private let identity: Curve25519.KeyAgreement.PrivateKey
    private let now: @Sendable () -> Date
    private let codeTTL: TimeInterval
    private let maxAttempts: Int

    public let macID: String
    private var activeCode: (code: String, expiresAt: Date, attempts: Int)?
    private var pending: [String: PendingPair] = [:]
    private var sessions: [String: RemoteCryptoSession] = [:]
    private var revoked: Set<String> = []

    public init(
        identity: Curve25519.KeyAgreement.PrivateKey = Curve25519.KeyAgreement.PrivateKey(),
        macID: String = UUID().uuidString,
        now: @escaping @Sendable () -> Date = Date.init,
        codeTTL: TimeInterval = 300,
        maxAttempts: Int = 5
    ) {
        self.identity = identity
        self.macID = macID
        self.now = now
        self.codeTTL = codeTTL
        self.maxAttempts = maxAttempts
    }

    public var publicKey: Data {
        identity.publicKey.rawRepresentation
    }

    /// 开始一次配对：返回 6 位码，显示在 Mac 上（也进 QR）。
    public func beginPairing() -> String {
        let code = String(format: "%06d", Int.random(in: 0...999_999))
        activeCode = (code, now().addingTimeInterval(codeTTL), 0)
        return code
    }

    /// iPhone 提交公钥和验证码。验证码正确则进入「等待 Mac 批准」。
    @discardableResult
    public func request(code: String, phonePublicKey: Data) throws -> String {
        guard var active = activeCode else { throw PairingError.expired }
        guard now() < active.expiresAt else {
            activeCode = nil
            throw PairingError.expired
        }
        guard active.attempts < maxAttempts else { throw PairingError.locked }
        guard code == active.code else {
            active.attempts += 1
            activeCode = active
            throw PairingError.invalidCode
        }
        let pairID = UUID().uuidString
        pending[pairID] = PendingPair(
            pairID: pairID,
            phonePublicKey: phonePublicKey,
            createdAt: now(),
            approved: false
        )
        activeCode = nil // 一码一用
        return pairID
    }

    /// Mac 上点了「允许」：派生 Mac 侧会话。
    @discardableResult
    public func approve(pairID: String) throws -> Bool {
        guard var item = pending[pairID] else { throw PairingError.unknownPair }
        guard !revoked.contains(pairID) else { throw PairingError.alreadyRevoked }
        guard let phoneKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: item.phonePublicKey) else {
            throw PairingError.unknownPair
        }
        let session = try RemoteCryptoSession(
            localPrivate: identity,
            peerPublic: phoneKey,
            pairID: pairID,
            isInitiator: false
        )
        sessions[pairID] = session
        item.approved = true
        pending[pairID] = item
        return true
    }

    public func deny(pairID: String) {
        pending[pairID] = nil
    }

    public func revoke(pairID: String) {
        revoked.insert(pairID)
        sessions[pairID] = nil
        pending[pairID] = nil
    }

    public func isRevoked(_ pairID: String) -> Bool {
        revoked.contains(pairID)
    }

    /// 已批准且未撤销的会话；中继转发前用它确认身份。
    public func session(for pairID: String) -> RemoteCryptoSession? {
        guard !revoked.contains(pairID) else { return nil }
        return sessions[pairID]
    }
}
