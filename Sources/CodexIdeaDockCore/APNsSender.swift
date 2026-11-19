import CryptoKit
import Foundation

/// 直接用 APNs HTTP/2 发推送，不需要自建服务端。
///
/// 需要三样东西：
/// - 团队级 APNs 私钥（`.p8`，用户自己保存，**不随 app 分发**）
/// - Key ID（Apple 下载文件名 `AuthKey_<KeyID>.p8` 里带的那 10 位）
/// - 手机的 device token（由 iPhone 通过配对通道上报，见 `POST /v1/push/token`）
public struct APNsSender: Sendable {
    public enum Environment: String, Sendable {
        case development
        case production

        var host: String {
            switch self {
            case .development: "api.sandbox.push.apple.com"
            case .production: "api.push.apple.com"
            }
        }
    }

    public struct Configuration: Sendable {
        /// `.p8` 私钥文件路径；文件不存在等于没配置。
        public var keyPath: String?
        public var keyID: String?
        public var teamID: String?
        /// 推送主题＝接收推送的 iOS app 的 bundle id。
        public var topic: String
        public var environment: Environment
        public var session: URLSession

        public init(
            keyPath: String? = nil,
            keyID: String? = nil,
            teamID: String? = nil,
            topic: String = "com.archintera.FlowCue",
            environment: Environment = .production,
            session: URLSession = .shared
        ) {
            self.keyPath = keyPath
            self.keyID = keyID
            self.teamID = teamID
            self.topic = topic
            self.environment = environment
            self.session = session
        }
    }

    public enum PushError: LocalizedError, Equatable {
        case notConfigured
        case invalidKey
        case rejected(String)

        public var errorDescription: String? {
            switch self {
            case .notConfigured: "APNs 未配置（缺少 .p8 路径 / Key ID / Team ID）"
            case .invalidKey: "APNs 私钥无法解析"
            case let .rejected(reason): "APNs 拒绝：\(reason)"
            }
        }
    }

    private let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public var isConfigured: Bool {
        guard let path = configuration.keyPath,
              let keyID = configuration.keyID, !keyID.isEmpty,
              let teamID = configuration.teamID, !teamID.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    /// 发一条可见横幅。`threadID` 用来让同一会话的通知折叠在一起。
    public func send(
        deviceToken: String,
        title: String,
        body: String,
        threadID: String? = nil
    ) async throws {
        guard isConfigured else { throw PushError.notConfigured }
        let jwt = try authorizationToken()
        guard let url = URL(string: "https://\(configuration.environment.host)/3/device/\(deviceToken)") else {
            throw PushError.notConfigured
        }

        var aps: [String: Any] = [
            "alert": ["title": title, "body": body],
            "sound": "default",
        ]
        if let threadID { aps["thread-id"] = threadID }
        let payload: [String: Any] = ["aps": aps]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        request.setValue(configuration.topic, forHTTPHeaderField: "apns-topic")
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await configuration.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PushError.invalidKey }
        guard http.statusCode == 200 else {
            let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["reason"] as? String
            throw PushError.rejected(reason ?? "HTTP \(http.statusCode)")
        }
    }

    // MARK: JWT

    private func authorizationToken() throws -> String {
        guard let path = configuration.keyPath,
              let keyID = configuration.keyID,
              let teamID = configuration.teamID else {
            throw PushError.notConfigured
        }
        guard let pem = try? String(contentsOfFile: path, encoding: .utf8),
              let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) else {
            throw PushError.invalidKey
        }

        let header = #"{"alg":"ES256","kid":"\#(keyID)"}"#
        let claims = #"{"iss":"\#(teamID)","iat":\#(Int(Date().timeIntervalSince1970))}"#
        let signingInput = "\(Self.base64url(Data(header.utf8))).\(Self.base64url(Data(claims.utf8)))"
        // APNs 要的是 JWT 的原始 R||S 签名，不是 DER。
        let signature = try key.signature(for: Data(signingInput.utf8))
        return "\(signingInput).\(Self.base64url(signature.rawRepresentation))"
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// `~/.flowcue/apns.json` 里的本机配置。密钥由用户自己保存，不进 app 包。
public struct APNsSettings: Codable, Sendable {
    public var keyPath: String
    public var keyID: String
    public var teamID: String
    public var environment: String

    public static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".flowcue/apns.json")
    }

    public static func load(from url: URL = defaultURL) -> APNsSettings? {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(APNsSettings.self, from: data),
              !settings.keyPath.isEmpty, !settings.keyID.isEmpty, !settings.teamID.isEmpty else {
            return nil
        }
        return settings
    }

    public func sender(environmentOverride: String? = nil, session: URLSession = .shared) -> APNsSender {
        let name = environmentOverride ?? environment
        return APNsSender(configuration: APNsSender.Configuration(
            keyPath: keyPath,
            keyID: keyID,
            teamID: teamID,
            environment: name == "development" ? .development : .production,
            session: session
        ))
    }
}
