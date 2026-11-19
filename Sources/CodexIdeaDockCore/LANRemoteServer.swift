import Foundation
import Network

/// A small Bonjour-advertised HTTP server for the explicit same-network
/// iPhone -> Mac continuation flow. No CloudKit entitlement is required.
@MainActor
public final class LANRemoteServer {
    public private(set) var isRunning = false
    public private(set) var port: UInt16?
    public let pairingCode: String

    private let bridge: any CodexBridging
    private let executorID: UUID
    private let executor: RemoteCommandExecutor
    private let reader: CodexSessionReplyReader
    private let dshBridge: DSHBridgeClient
    private let dshSessions: DSHSessionReader
    private let store: IdeaDockStore?
    private var listener: NWListener?
    private var connections: [UUID: HTTPConnection] = [:]
    /// Codex 会话列表要拉起 app-server 再逐个读最新回复，一次 3 秒起；
    /// 手机每隔几秒就问一次，所以缓存一小段时间。
    private var threadCache: (snapshots: [RemoteThreadSnapshot], at: Date)?
    private static let threadCacheTTL: TimeInterval = 20
    /// 固定监听端口，让手机缓存的地址在 Mac 重启后依然有效。
    public static let preferredPort: UInt16 = 47824

    public init(
        executorID: UUID,
        pairingCode: String,
        bridge: any CodexBridging,
        ledgerURL: URL,
        sessionsDirectory: URL? = nil,
        dshBridge: DSHBridgeClient = DSHBridgeClient(),
        store: IdeaDockStore? = nil
    ) throws {
        self.executorID = executorID
        self.pairingCode = pairingCode
        self.bridge = bridge
        self.executor = try RemoteCommandExecutor(executorID: executorID, ledgerURL: ledgerURL, bridge: bridge)
        self.reader = CodexSessionReplyReader(sessionsDirectory: sessionsDirectory ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions"))
        self.dshBridge = dshBridge
        self.dshSessions = DSHSessionReader()
        self.store = store
    }

    public func start() throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // 固定端口：以前用临时端口，Mac 一重启端口就变，手机缓存的地址随之失效，
        // 表现就是「Mac 好好开着却一直 Connection lost」。端口被占时才退回临时端口。
        let preferred = NWEndpoint.Port(rawValue: Self.preferredPort)
        let listener: NWListener
        if let preferred, let fixed = try? NWListener(using: parameters, on: preferred) {
            listener = fixed
        } else {
            listener = try NWListener(using: parameters)
        }
        listener.service = NWListener.Service(name: "FlowCue", type: "_flowcue._tcp")
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                self?.accept(connection)
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isRunning = true
                    self.port = self.listener?.port?.rawValue
                    // 预热缓存，免得手机第一条请求还要等 Codex 起 app-server。
                    Task { _ = try? await self.threadSnapshots() }
                case .failed, .cancelled:
                    self.isRunning = false
                    self.port = nil
                default:
                    break
                }
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    /// 缓存期内直接返回；过期才真的去问 Codex。
    private func threadSnapshots() async throws -> [RemoteThreadSnapshot] {
        if let cache = threadCache,
           Date().timeIntervalSince(cache.at) < Self.threadCacheTTL {
            return cache.snapshots
        }
        let contexts = try await bridge.listThreads()
        let snapshots = contexts.map { context in
            RemoteThreadSnapshot(
                id: context.id,
                title: context.title,
                projectDirectory: context.projectDirectory,
                lastReply: reader.latestAssistantText(threadID: context.id) ?? "",
                updatedAt: context.recency,
                executorID: executorID
            )
        }
        threadCache = (snapshots, Date())
        return snapshots
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        isRunning = false
        port = nil
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let handler = HTTPConnection(connection: connection) { [weak self] request in
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let response = try await self.respond(to: request)
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                } catch {
                    connection.send(content: Self.response(status: 500, body: Data("{}".utf8)), completion: .contentProcessed { _ in connection.cancel() })
                }
                self.connections.removeValue(forKey: id)
            }
        }
        connections[id] = handler
        handler.start()
    }

    /// 协议版本：只在「老客户端会解读错」时才 +1。Mac 作为服务端至少兼容上一版。
    public static let protocolVersion = 1
    public static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
    /// 最近一次收到请求的客户端版本（nil 表示对方没带）。
    public private(set) static var lastClientVersion: String?

    private func respond(to request: HTTPRequest) async throws -> Data {
        if request.path == "/v1/ping" {
            // `version` 保留给旧客户端；`protocol` 与 `appVersion` 给新客户端做版本握手
            let payload: [String: String] = [
                "name": "FlowCue",
                "version": String(Self.protocolVersion),
                "protocol": String(Self.protocolVersion),
                "appVersion": Self.appVersion
            ]
            return Self.response(status: 200, body: try JSONEncoder().encode(payload))
        }
        if let clientVersion = request.headers["x-flowcue-version"] {
            Self.lastClientVersion = clientVersion
        }
        guard request.headers["authorization"] == "Bearer \(pairingCode)" else {
            return Self.response(status: 401, body: Data("{}".utf8))
        }
        switch (request.method, request.path) {
        case ("GET", "/v1/threads"):
            let snapshots = try await threadSnapshots()
            return Self.response(status: 200, body: try JSONEncoder().encode(snapshots))
        case ("GET", let path) where path.hasPrefix("/v1/dsh/subagents/"):
            let encoded = String(path.dropFirst("/v1/dsh/subagents/".count))
            guard let parentID = encoded.removingPercentEncoding, !parentID.isEmpty else {
                return Self.response(status: 400, body: Data("[]".utf8))
            }
            return Self.response(status: 200, body: try JSONEncoder().encode(dshSessions.subagents(ofParent: parentID)))
        case ("GET", "/v1/dsh/sessions"):
            let sessions = dshSessions.sessions()
            return Self.response(status: 200, body: try JSONEncoder().encode(sessions))
        case ("GET", let path) where path.hasPrefix("/v1/dsh/sessions/") && path.hasSuffix("/messages"):
            let encoded = String(path.dropFirst("/v1/dsh/sessions/".count).dropLast("/messages".count))
            guard let sessionID = encoded.removingPercentEncoding, !sessionID.isEmpty else {
                return Self.response(status: 400, body: Data("[]".utf8))
            }
            let messages = dshSessions.messages(sessionID: sessionID)
            return Self.response(status: 200, body: try JSONEncoder().encode(messages))
        case ("GET", "/v1/dsh/approvals"):
            struct Response: Encodable {
                let available: Bool
                let pending: [DSHRemoteApproval]
            }
            guard dshBridge.isConfigured else {
                return Self.response(status: 200, body: try JSONEncoder().encode(Response(available: false, pending: [])))
            }
            do {
                // 这是 iPhone 发起的轮询，只有它能代表「手机在线」；
                // 桥接靠这个标记决定要不要扣住桌面审批卡。
                let approvals = try await dshBridge.pending(source: "phone")
                return Self.response(status: 200, body: try JSONEncoder().encode(Response(available: true, pending: approvals)))
            } catch {
                return Self.response(status: 200, body: try JSONEncoder().encode(Response(available: true, pending: [])))
            }
        case ("POST", "/v1/dsh/send"):
            let message = try JSONDecoder().decode(DSHRemoteMessage.self, from: request.body)
            do {
                try await dshBridge.send(sessionID: message.sessionId, text: message.text, images: message.images ?? [])
                return Self.response(status: 200, body: Data("{}".utf8))
            } catch {
                return Self.response(status: 409, body: Data("{}".utf8))
            }
        case ("POST", "/v1/dsh/decide"):
            let decision = try JSONDecoder().decode(DSHRemoteDecision.self, from: request.body)
            do {
                try await dshBridge.decide(id: decision.id, decision: decision.decision)
                return Self.response(status: 200, body: Data("{}".utf8))
            } catch {
                return Self.response(status: 409, body: Data("{}".utf8))
            }
        case ("POST", "/v1/ideas"):
            guard let store else {
                return Self.response(status: 503, body: Data("{}".utf8))
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let idea = try? decoder.decode(RemoteIdea.self, from: request.body),
                  store.upsertRemoteIdea(idea) else {
                return Self.response(status: 422, body: Data("{}".utf8))
            }
            return Self.response(status: 200, body: Data("{}".utf8))
        case ("POST", "/v1/push/token"):
            // 手机的 APNs device token。Mac 用它直接向苹果推送，不需要服务端。
            struct PushToken: Decodable {
                let token: String
                let environment: String?
            }
            guard let report = try? JSONDecoder().decode(PushToken.self, from: request.body),
                  report.token.count >= 32 else {
                return Self.response(status: 400, body: Data("{}".utf8))
            }
            UserDefaults.standard.set(report.token, forKey: "FlowCue.pushDeviceToken")
            if let environment = report.environment {
                UserDefaults.standard.set(environment, forKey: "FlowCue.pushEnvironment")
            }
            return Self.response(status: 200, body: Data("{}".utf8))
        case ("POST", "/v1/pro/expiry"):
            struct Report: Decodable { let expiry: String? }
            guard let report = try? JSONDecoder().decode(Report.self, from: request.body) else {
                return Self.response(status: 400, body: Data("{}".utf8))
            }
            if let raw = report.expiry {
                guard let date = ISO8601DateFormatter().date(from: raw) else {
                    return Self.response(status: 400, body: Data("{}".utf8))
                }
                ProEntitlement.publish(expiry: date)
            } else {
                ProEntitlement.publish(expiry: nil)
            }
            return Self.response(status: 200, body: Data("{}".utf8))
        case ("GET", let path) where path.hasPrefix("/v1/threads/") && path.hasSuffix("/messages"):
            let encoded = String(path.dropFirst("/v1/threads/".count).dropLast("/messages".count))
            guard let threadID = encoded.removingPercentEncoding, !threadID.isEmpty else {
                return Self.response(status: 400, body: Data("[]".utf8))
            }
            let messages = reader.messages(threadID: threadID)
            return Self.response(status: 200, body: try JSONEncoder().encode(messages))
        case ("POST", "/v1/send"):
            let command = try JSONDecoder().decode(RemoteCommand.self, from: request.body)
            let state = try await executor.execute(command)
            let reply = reader.latestAssistantText(threadID: command.threadID, after: command.createdAt)
            return Self.response(status: 200, body: try JSONEncoder().encode(RemoteCommandResult(id: command.id, state: state, reply: reply)))
        default:
            return Self.response(status: 404, body: Data("{}".utf8))
        }
    }

    private static func response(status: Int, body: Data) -> Data {
        let reason = status == 200 ? "OK" : status == 401 ? "Unauthorized" : status == 404 ? "Not Found" : "Error"
        var data = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        data.append(body)
        return data
    }
}

private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

@MainActor
private final class HTTPConnection {
    private let connection: NWConnection
    private let onRequest: (HTTPRequest) -> Void
    private var buffer = Data()
    private var started = false

    init(connection: NWConnection, onRequest: @escaping (HTTPRequest) -> Void) {
        self.connection = connection
        self.onRequest = onRequest
    }

    func start() {
        guard !started else { return }
        started = true
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .ready = state { self.receive() }
            }
        }
        connection.start(queue: .main)
    }

    func cancel() {
        connection.cancel()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let data { self.buffer.append(data) }
                if let request = self.parseIfComplete() {
                    self.onRequest(request)
                    return
                }
                if isComplete || error != nil {
                    self.connection.cancel()
                    return
                }
                self.receive()
            }
        }
    }

    private func parseIfComplete() -> HTTPRequest? {
        guard let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = buffer[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let path = String(parts[1].split(separator: "?").first ?? "")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerRange.upperBound
        guard buffer.count >= bodyStart + contentLength else { return nil }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }
}
