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
        public let phoneID: String?
        public let phoneName: String?
    }

    /// 已批准的一台手机。设置页用它显示可辨认的名字/时间，而不是一串 pairID。
    public struct PairedPhone: Sendable, Codable, Identifiable, Equatable {
        public let pairID: String
        public let phonePublicKey: Data
        public let phoneID: String?
        public let phoneName: String?
        public let pairedAt: Date
        public var lastSeenAt: Date?

        public var id: String { pairID }
        public var displayName: String {
            let trimmed = phoneName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? "未命名手机" : trimmed
        }

        public init(
            pairID: String, phonePublicKey: Data,
            phoneID: String? = nil, phoneName: String? = nil,
            pairedAt: Date, lastSeenAt: Date? = nil
        ) {
            self.pairID = pairID
            self.phonePublicKey = phonePublicKey
            self.phoneID = phoneID
            self.phoneName = phoneName
            self.pairedAt = pairedAt
            self.lastSeenAt = lastSeenAt
        }
    }

    public struct Approval: Sendable, Equatable {
        public let approved: Bool
        /// 同一台手机重新配对/超过上限时被自动作废的旧 pairID，
        /// 中继客户端据此通知中继关掉旧 socket。
        public let replacedPairIDs: [String]
    }

    private let identity: Curve25519.KeyAgreement.PrivateKey
    /// 身份密钥与已批准配对落盘：Mac 重启后手机不该重新配对。
    private let storeDirectory: URL
    private let now: @Sendable () -> Date
    private let codeTTL: TimeInterval
    private let maxAttempts: Int

    public let macID: String
    private var activeCode: (code: String, expiresAt: Date, attempts: Int)?
    private var pending: [String: PendingPair] = [:]
    private var sessions: [String: RemoteCryptoSession] = [:]
    /// 已批准配对（含手机名/时间，落盘用）
    private var pairedPhones: [String: PairedPhone] = [:]
    private var revoked: Set<String> = []
    private var lastPersistedAt = Date.distantPast
    /// 上限只防列表无限增长；正常使用一台手机只会保留一条。
    private let maxPairedPhones = 8

    public init(
        identity: Curve25519.KeyAgreement.PrivateKey? = nil,
        macID: String = UUID().uuidString,
        now: @escaping @Sendable () -> Date = Date.init,
        codeTTL: TimeInterval = 300,
        maxAttempts: Int = 5,
        storeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".flowcue")
    ) {
        self.storeDirectory = storeDirectory
        self.identity = identity ?? Self.loadIdentity(in: storeDirectory)
        self.macID = macID
        self.now = now
        self.codeTTL = codeTTL
        self.maxAttempts = maxAttempts
        // 启动时恢复已批准的配对
        for phone in Self.loadPairs(in: storeDirectory) {
            guard let phoneKey = try? Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: phone.phonePublicKey
            ) else { continue }
            pairedPhones[phone.pairID] = phone
            if let session = try? RemoteCryptoSession(
                localPrivate: self.identity,
                peerPublic: phoneKey,
                pairID: phone.pairID,
                isInitiator: false
            ) {
                sessions[phone.pairID] = session
            }
        }
    }

    /// Mac 的长期公钥（发给手机做密钥协商）。
    public var publicKey: Data { identity.publicKey.rawRepresentation }

    // MARK: 持久化

    private static func identityURL(_ dir: URL) -> URL {
        dir.appendingPathComponent("remote-identity.bin")
    }
    private static func pairsURL(_ dir: URL) -> URL {
        dir.appendingPathComponent("remote-pairs.json")
    }

    private static func loadIdentity(in dir: URL) -> Curve25519.KeyAgreement.PrivateKey {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: identityURL(dir)),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        try? key.rawRepresentation.write(to: identityURL(dir))
        // 私钥文件只给当前用户读写
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: identityURL(dir).path)
        return key
    }

    private struct StoredPairs: Codable {
        let version: Int
        let pairs: [PairedPhone]
    }

    private static func loadPairs(in dir: URL) -> [PairedPhone] {
        guard let data = try? Data(contentsOf: pairsURL(dir)) else { return [] }
        let decoder = JSONDecoder()
        if let stored = try? decoder.decode(StoredPairs.self, from: data) {
            return stored.pairs
        }
        // 旧格式：{ pairID: base64(phonePublicKey) }，没有名字和时间。
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return []
        }
        return raw.compactMap { pairID, base64 in
            guard let keyData = Data(base64Encoded: base64) else { return nil }
            return PairedPhone(
                pairID: pairID,
                phonePublicKey: keyData,
                pairedAt: .distantPast
            )
        }
    }

    private func persistPairs() {
        let stored = StoredPairs(version: 2, pairs: pairedPhones.values.sorted { $0.pairID < $1.pairID })
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: Self.pairsURL(storeDirectory))
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: Self.pairsURL(storeDirectory).path
        )
        lastPersistedAt = now()
    }

    /// 开始一次配对：返回 6 位码，显示在 Mac 上（也进 QR）。
    public func beginPairing() -> String {
        let code = String(format: "%06d", Int.random(in: 0...999_999))
        activeCode = (code, now().addingTimeInterval(codeTTL), 0)
        return code
    }

    /// iPhone 提交公钥和验证码。验证码正确则进入「等待 Mac 批准」。
    @discardableResult
    public func request(
        code: String,
        phonePublicKey: Data,
        pairID externalID: String? = nil,
        phoneID: String? = nil,
        phoneName: String? = nil
    ) throws -> String {
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
        // 远程场景下 pairID 由中继分配，加密信封里的 pair 必须与路由一致
        let pairID = externalID ?? UUID().uuidString
        pending[pairID] = PendingPair(
            pairID: pairID,
            phonePublicKey: phonePublicKey,
            createdAt: now(),
            approved: false,
            phoneID: phoneID,
            phoneName: phoneName
        )
        activeCode = nil // 一码一用
        return pairID
    }

    /// Mac 上点了「允许」：派生 Mac 侧会话。
    @discardableResult
    public func approve(pairID: String) throws -> Approval {
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
        var replaced: [String] = []

        // 同一台手机重新配对：旧记录自动作废，否则设置页每次重装/重配都会多一条。
        if let phoneID = item.phoneID, !phoneID.isEmpty {
            for existing in pairedPhones.values
            where existing.pairID != pairID && existing.phoneID == phoneID {
                revoked.insert(existing.pairID)
                sessions[existing.pairID] = nil
                pairedPhones[existing.pairID] = nil
                replaced.append(existing.pairID)
            }
        }

        pairedPhones[pairID] = PairedPhone(
            pairID: pairID,
            phonePublicKey: item.phonePublicKey,
            phoneID: item.phoneID,
            phoneName: item.phoneName,
            pairedAt: now(),
            lastSeenAt: now()
        )

        // 超过上限时按最近使用时间淘汰最旧的，防止旧安装无限堆积。
        while pairedPhones.count > maxPairedPhones,
              let oldest = pairedPhones.values.min(by: {
                  ($0.lastSeenAt ?? $0.pairedAt) < ($1.lastSeenAt ?? $1.pairedAt)
              }) {
            revoked.insert(oldest.pairID)
            sessions[oldest.pairID] = nil
            pairedPhones[oldest.pairID] = nil
            replaced.append(oldest.pairID)
        }

        item.approved = true
        pending[pairID] = item
        persistPairs()
        return Approval(approved: true, replacedPairIDs: replaced)
    }

    public func deny(pairID: String) {
        pending[pairID] = nil
    }

    public func revoke(pairID: String) {
        revoked.insert(pairID)
        sessions[pairID] = nil
        pairedPhones[pairID] = nil
        pending[pairID] = nil
        persistPairs()
    }

    /// 设置页「撤销全部」；返回被撤销的 pairID，供中继客户端逐个关 socket。
    @discardableResult
    public func revokeAll() -> [String] {
        let ids = Array(pairedPhones.keys)
        for pairID in ids {
            revoked.insert(pairID)
            sessions[pairID] = nil
            pairedPhones[pairID] = nil
            pending[pairID] = nil
        }
        persistPairs()
        return ids
    }

    public func isRevoked(_ pairID: String) -> Bool {
        revoked.contains(pairID)
    }

    /// 已批准的配对（设置页列出设备），最近使用的在前。
    public var activePairIDs: [String] {
        pairedPhoneInfos.map(\.pairID)
    }

    /// 设置页用：可辨认的手机名 + 配对/最近使用时间。
    public var pairedPhoneInfos: [PairedPhone] {
        pairedPhones.values.sorted {
            ($0.lastSeenAt ?? $0.pairedAt) > ($1.lastSeenAt ?? $1.pairedAt)
        }
    }

    /// 已批准的配对数（设置页展示）。
    public var approvedCount: Int {
        pairedPhones.count
    }

    /// 配对状态：手机端轮询用。
    public func status(for pairID: String) -> String? {
        if revoked.contains(pairID) { return "revoked" }
        if sessions[pairID] != nil { return "approved" }
        if let item = pending[pairID] { return item.approved ? "approved" : "pending" }
        return nil
    }

    /// 已批准且未撤销的会话；中继转发前用它确认身份。
    public func session(for pairID: String) -> RemoteCryptoSession? {
        guard !revoked.contains(pairID) else { return nil }
        return sessions[pairID]
    }

    /// 用存储中的会话解密，并把更新后的 seq 写回去。
    ///
    /// 注意：`RemoteCryptoSession` 是 struct。以前中继客户端拿
    /// `session(for:)` 的副本去 open/seal，seq 只改在副本上：
    /// 每条响应都从 seq=1 开始，手机只认第一条，之后全部当成重放丢弃，
    /// 表现就是「会话一直加载」。所有收发必须经过这两个方法。
    public func openEnvelope(_ envelope: RemoteEnvelope) throws -> Data {
        guard !revoked.contains(envelope.pair), var session = sessions[envelope.pair] else {
            throw PairingError.notApproved
        }
        let plaintext = try session.open(envelope)
        sessions[envelope.pair] = session
        if var phone = pairedPhones[envelope.pair] {
            phone.lastSeenAt = now()
            pairedPhones[envelope.pair] = phone
            // 不要每个请求都写盘；一分钟一次足够。
            if now().timeIntervalSince(lastPersistedAt) > 60 {
                persistPairs()
            }
        }
        return plaintext
    }

    public func sealEnvelope(pairID: String, plaintext: Data) throws -> RemoteEnvelope {
        guard !revoked.contains(pairID), var session = sessions[pairID] else {
            throw PairingError.notApproved
        }
        let envelope = try session.seal(plaintext)
        sessions[pairID] = session
        return envelope
    }
}
