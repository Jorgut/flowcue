import Foundation

/// 隧道里传输的请求（加密前）。
public struct RemoteRequest: Codable, Sendable {
    public let id: String
    public let kind: String        // "request"
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data?

    public init(id: String = UUID().uuidString, method: String, path: String,
                headers: [String: String] = [:], body: Data? = nil) {
        self.id = id
        self.kind = "request"
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

/// 隧道里传输的响应（加密前）。
public struct RemoteResponse: Codable, Sendable {
    public let id: String
    public let kind: String        // "response"
    public let status: Int
    public let headers: [String: String]
    public let body: Data?
    /// body 的压缩方式；nil 表示明文。大响应（DSH 67 条消息可达 850KB）
    /// base64 后会超过 Cloudflare WebSocket 1MiB 上限，导致连接被关闭。
    public let encoding: String?

    public init(id: String, status: Int, headers: [String: String] = ["content-type": "application/json"], body: Data?) {
        self.id = id
        self.kind = "response"
        self.status = status
        self.headers = headers
        if let body, body.count > 32 * 1024,
           let compressed = try? (body as NSData).compressed(using: .zlib) as Data,
           compressed.count + 64 < body.count {
            self.body = compressed
            self.encoding = "zlib"
        } else {
            self.body = body
            self.encoding = nil
        }
    }
}

/// 大响应拆分帧。Cloudflare WebSocket 单条消息上限 1MiB，DSH 会话里
/// 内联的 base64 截图会让响应超过上限；拆成多个加密 chunk 后逐帧发送。
public struct RemoteChunk: Codable, Sendable {
    public let kind: String
    public let id: String
    public let index: Int
    public let total: Int
    public let data: Data

    public init(id: String, index: Int, total: Int, data: Data) {
        self.kind = "chunk"
        self.id = id
        self.index = index
        self.total = total
        self.data = data
    }
}
