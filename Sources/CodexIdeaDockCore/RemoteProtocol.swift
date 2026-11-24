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

    public init(id: String, status: Int, headers: [String: String] = ["content-type": "application/json"], body: Data?) {
        self.id = id
        self.kind = "response"
        self.status = status
        self.headers = headers
        self.body = body
    }
}
