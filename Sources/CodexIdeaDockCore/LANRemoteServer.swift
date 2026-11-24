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
                    // 同时预热通用 Agent 统计：手机连上 Agents 页时立刻就有内容。
                    self.warmAgentSummary()
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
    /// 一个可用的 skill（供手机端斜杠菜单展示）。
    public struct RemoteSkill: Codable, Identifiable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let summary: String
    }

    /// 扫描本机常见 skill 目录。前端只用名字和一句话描述。
    private func localSkills() -> [RemoteSkill] {
        let roots = [
            ".agents/skills",
            ".codex/skills",
            ".claude/skills",
            ".dsh/skills"
        ].map { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent($0) }
        var seen = Set<String>()
        var result: [RemoteSkill] = []
        for root in roots {
            let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for entry in entries {
                let skillFile = entry.appendingPathComponent("SKILL.md")
                guard let text = try? String(contentsOfFile: skillFile.path, encoding: .utf8) else { continue }
                var name = entry.lastPathComponent
                var summary = ""
                func clean(_ raw: Substring) -> String {
                    var value = raw.trimmingCharacters(in: .whitespaces)
                    // YAML 里常写成 name: "xxx"，去掉两端引号
                    if value.hasPrefix("\"") || value.hasPrefix("'") { value.removeFirst() }
                    if value.hasSuffix("\"") || value.hasSuffix("'") { value.removeLast() }
                    return value
                }
                for line in text.split(separator: "\n").prefix(12) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("name:") {
                        let value = clean(trimmed.dropFirst(5))
                        if !value.isEmpty { name = value }
                    } else if trimmed.hasPrefix("description:") {
                        summary = String(clean(trimmed.dropFirst(12)).prefix(120))
                    }
                }
                guard !name.isEmpty, !seen.contains(name) else { continue }
                seen.insert(name)
                result.append(RemoteSkill(id: name, name: name, summary: summary))
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    /// 通用 Agent 接口用的编码器（日期走 ISO8601，和手机端一致）。
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// 最近一次收到请求的客户端版本（nil 表示对方没带）。
    public private(set) static var lastClientVersion: String?
    /// 通用 Agent 层：所有 Agent 走同一套 list/messages/send。
    private let agentService = AgentService.default
    /// 会话/项目计数的缓存（列会话要读各家目录，不能每次请求都扫）。
    private var agentSummaryCache: [String: RemoteAgentInfo] = [:]
    private var agentSummaryCacheAt: Date?
    private var agentSummaryTask: Task<[RemoteAgentInfo], Never>?
    /// 来自 Claude hooks 等外部通道的审批请求（DSH 走桥接，不在这里）。
    private struct ExternalApproval {
        let id: String
        let agent: String
        let sessionId: String?
        let title: String
        let detail: String?
        let createdAt: Date
        var status: String  // pending / approved / denied
    }
    private var externalApprovals: [ExternalApproval] = []
    /// Remote 配对：6 位码、批准、撤销都在这里。
    /// 中继客户端需要读取会话，所以暴露为 internal 可读。
    let pairing = RemotePairingManager()
    /// 各 Agent 的会话列表缓存（30 秒）：手机上反复进出同一个 Agent 不必重扫。
    private var agentSessionsCache: [String: (items: [RemoteAgentSession], at: Date)] = [:]
    /// 手机轮询审批接口的次数。用来判断「手机是否已经自己连回来」——
    /// 这个接口只有手机会调，本机测试不会干扰计数。
    private var phonePollCount = 0
    /// /v1/skills 被请求的次数：用来确认手机端斜杠菜单到底有没有发请求。
    private var skillsRequestCount = 0
    private var lastPhonePollAt: Date?

    /// 启动后在后台预热一次统计，避免手机刚连上时等几秒。
    public func warmAgentSummary() {
        Task { _ = await agentSummaries() }
        // 顺便补扫「哪些会话是示例」，过滤时就不用读日志了。
        if let directory = DSHSessionReader().sessionsDirectoryIfAvailable {
            let ids = DSHSessionReader().sessions(limit: 500).map(\.id)
            Task.detached(priority: .utility) {
                DSHSeededIndex.refresh(sessionsDirectory: directory, sessionIDs: ids)
            }
        }
    }

    /// 装上且被支持的 Agent，附会话数与项目数（60 秒缓存 + 并发去重）。
    private func agentSummaries() async -> [RemoteAgentInfo] {
        if let at = agentSummaryCacheAt, Date().timeIntervalSince(at) < 60, !agentSummaryCache.isEmpty {
            return agentSummaryCache.values.sorted { $0.displayName < $1.displayName }
        }
        // 冷启动要扫三家的会话目录（约 7 秒），并发请求共享同一次计算。
        if let inFlight = agentSummaryTask {
            return await inFlight.value
        }
        let task = Task { await self.computeAgentSummaries() }
        agentSummaryTask = task
        let result = await task.value
        agentSummaryTask = nil
        return result
    }

    private func computeAgentSummaries() async -> [RemoteAgentInfo] {
        var result: [String: RemoteAgentInfo] = [:]
        let supported = Set(agentService.supportedAgentIDs)
        for record in AgentDiscovery.scan() where supported.contains(record.id) {
            let sessions = (try? await agentService.sessions(for: record.id, limit: 1000)) ?? []
            let projects = Set(sessions.compactMap { $0.projectPath }.filter { !$0.isEmpty })
            result[record.id] = RemoteAgentInfo(
                id: record.id,
                displayName: record.displayName,
                sessionCount: sessions.count,
                projectCount: projects.count,
                canSend: record.capabilities.contains(.drive)
            )
        }
        // 支持的适配器即使没被目录扫到，也列出来（例如 DSH 靠桥接）
        for id in supported where result[id] == nil {
            let sessions = (try? await agentService.sessions(for: id, limit: 1000)) ?? []
            let projects = Set(sessions.compactMap { $0.projectPath }.filter { !$0.isEmpty })
            result[id] = RemoteAgentInfo(
                id: id,
                displayName: id.capitalized,
                sessionCount: sessions.count,
                projectCount: projects.count,
                canSend: true
            )
        }
        agentSummaryCache = result
        agentSummaryCacheAt = Date()
        return result.values.sorted { $0.displayName < $1.displayName }
    }

    private static func remoteSession(_ session: AgentSession) -> RemoteAgentSession {
        RemoteAgentSession(
            id: session.id,
            agentID: session.agentID,
            title: session.title,
            projectPath: session.projectPath,
            updatedAt: session.updatedAt,
            messageCount: session.messageCount,
            activity: session.activity
        )
    }

    private static func remoteMessage(_ message: AgentMessage) -> RemoteAgentMessage {
        RemoteAgentMessage(
            id: message.id,
            role: message.role.rawValue,
            text: message.text,
            timestamp: message.timestamp
        )
    }

    /// 中继隧道的复用入口：解密后的请求交给同一套路由，返回状态码和 body。
    /// LAN 直连和中继因此没有第二条代码路径——端点不会分叉。
    public func dispatchRemote(
        method: String,
        path: String,
        headers: [String: String],
        body: Data? = nil
    ) async -> (status: Int, body: Data) {
        let request = HTTPRequest(method: method, path: path, headers: headers, body: body ?? Data())
        guard let raw = try? await respond(to: request) else {
            return (500, Data("{}".utf8))
        }
        return Self.parseHTTPResponse(raw)
    }

    /// 从 `response(status:body:)` 生成的字节里取回状态码和 body。
    private static func parseHTTPResponse(_ raw: Data) -> (status: Int, body: Data) {
        guard let separator = raw.range(of: Data("\r\n\r\n".utf8)) else {
            return (500, raw)
        }
        let head = String(decoding: raw[..<separator.lowerBound], as: UTF8.self)
        let status = head
            .split(separator: " ")
            .dropFirst()
            .first
            .flatMap { Int($0) } ?? 500
        return (status, Data(raw[separator.upperBound...]))
    }

    private func respond(to request: HTTPRequest) async throws -> Data {
        // 只有 /v1/ping 公开：配对前客户端要靠它做版本握手。
        // 其余所有入口（含通用 Agent 接口）都必须在鉴权之后，
        // 否则局域网内任何人无需配对码就能读会话、发消息。
        if request.path == "/v1/ping" {
            let payload: [String: String] = [
                "name": "FlowCue",
                "version": String(Self.protocolVersion),
                "protocol": String(Self.protocolVersion),
                "appVersion": Self.appVersion,
                "phonePolls": String(phonePollCount),
                "skillsRequests": String(skillsRequestCount),
                "lastPhonePollAt": lastPhonePollAt.map { ISO8601DateFormatter().string(from: $0) } ?? ""
            ]
            return Self.response(status: 200, body: try JSONEncoder().encode(payload))
        }

        guard request.headers["authorization"] == "Bearer \(pairingCode)" else {
            return Self.response(status: 401, body: Data("{}".utf8))
        }

        if request.path == "/v1/dsh/approvals" {
            phonePollCount += 1
            lastPhonePollAt = Date()
        }
        // MARK: 通用 Agent 接口
        if request.method == "GET", request.path == "/v1/agents" {
            let agents = await agentSummaries()
            return Self.response(status: 200, body: (try? Self.encoder.encode(agents)) ?? Data("[]".utf8))
        }

        if request.path.hasPrefix("/v1/agents/") {
            let rest = String(request.path.dropFirst("/v1/agents/".count))
            let parts = rest.split(separator: "/").map(String.init)
            if parts.count >= 2, parts[1] == "sessions" {
                let agentID = parts[0].removingPercentEncoding ?? parts[0]
                if parts.count == 2 {
                    // GET /v1/agents/{id}/sessions
                    if let cached = agentSessionsCache[agentID],
                       Date().timeIntervalSince(cached.at) < 30 {
                        return Self.response(status: 200, body: (try? Self.encoder.encode(cached.items)) ?? Data("[]".utf8))
                    }
                    let sessions = (try? await agentService.sessions(for: agentID, limit: 200)) ?? []
                    let items = sessions.map(Self.remoteSession)
                    agentSessionsCache[agentID] = (items, Date())
                    return Self.response(status: 200, body: (try? Self.encoder.encode(items)) ?? Data("[]".utf8))
                }
                if parts.count >= 4 {
                    let sessionID = parts[2].removingPercentEncoding ?? parts[2]
                    let action = parts[3]
                    let sessions = (try? await agentService.sessions(for: agentID, limit: 1000)) ?? []
                    guard let session = sessions.first(where: { $0.id == sessionID }) else {
                        return Self.response(status: 404, body: Data("{}".utf8))
                    }
                    if action == "activity", request.method == "GET" {
                        let label = (agentService.adapter(for: agentID) as? DSHAgentAdapter)?
                            .activity(in: session)
                        let payload = ["activity": label ?? ""]
                        return Self.response(status: 200, body: (try? Self.encoder.encode(payload)) ?? Data("{}".utf8))
                    }
                    if action == "messages", request.method == "GET" {
                        let messages = (try? await agentService.messages(session)) ?? []
                        return Self.response(status: 200, body: (try? Self.encoder.encode(messages.map(Self.remoteMessage))) ?? Data("[]".utf8))
                    }
                    if action == "send", request.method == "POST" {
                        struct SendBody: Decodable { let text: String }
                        guard let body = try? JSONDecoder().decode(SendBody.self, from: request.body),
                              !body.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            return Self.response(status: 400, body: Data("{}".utf8))
                        }
                        do {
                            try await agentService.send(body.text, to: session)
                            return Self.response(status: 200, body: Data("{}".utf8))
                        } catch {
                            return Self.response(status: 409, body: Data("{}".utf8))
                        }
                    }
                }
            }
            return Self.response(status: 404, body: Data("{}".utf8))
        }

        if request.method == "GET", request.path == "/v1/skills" {
            skillsRequestCount += 1
            return Self.response(status: 200, body: (try? Self.encoder.encode(localSkills())) ?? Data("[]".utf8))
        }

        if let clientVersion = request.headers["x-flowcue-version"] {
            Self.lastClientVersion = clientVersion
        }
        switch (request.method, request.path) {
        case ("POST", "/v1/remote/pair/begin"):
            let code = await pairing.beginPairing()
            let macKey = await pairing.publicKey
            let macID = await pairing.macID
            let payload: [String: String] = [
                "code": code,
                "macID": macID,
                "publicKey": macKey.base64EncodedString()
            ]
            return Self.response(status: 200, body: try JSONEncoder().encode(payload))

        case ("POST", "/v1/remote/pair/request"):
            struct Body: Decodable {
                let code: String
                let phonePublicKey: String
            }
            guard let body = try? JSONDecoder().decode(Body.self, from: request.body),
                  let phoneKey = Data(base64Encoded: body.phonePublicKey) else {
                return Self.response(status: 400, body: Data("{}".utf8))
            }
            do {
                let pairID = try await pairing.request(code: body.code, phonePublicKey: phoneKey)
                return Self.response(status: 200, body: try JSONEncoder().encode(["pairID": pairID]))
            } catch {
                let reason = String(describing: error)
                return Self.response(status: 409, body: try JSONEncoder().encode(["error": reason]))
            }

        case ("GET", let path) where path.hasPrefix("/v1/remote/pair/status/"):
            let pairID = String(path.dropFirst("/v1/remote/pair/status/".count))
            let status = await pairing.status(for: pairID) ?? "unknown"
            return Self.response(status: 200, body: try JSONEncoder().encode(["status": status]))

        case ("POST", "/v1/remote/pair/approve"):
            struct Body: Decodable { let pairID: String }
            guard let body = try? JSONDecoder().decode(Body.self, from: request.body) else {
                return Self.response(status: 400, body: Data("{}".utf8))
            }
            _ = try? await pairing.approve(pairID: body.pairID)
            return Self.response(status: 200, body: Data("{}".utf8))

        case ("POST", "/v1/remote/pair/deny"):
            struct Body: Decodable { let pairID: String }
            guard let body = try? JSONDecoder().decode(Body.self, from: request.body) else {
                return Self.response(status: 400, body: Data("{}".utf8))
            }
            await pairing.deny(pairID: body.pairID)
            return Self.response(status: 200, body: Data("{}".utf8))

        case ("POST", "/v1/remote/pair/revoke"):
            struct Body: Decodable { let pairID: String }
            guard let body = try? JSONDecoder().decode(Body.self, from: request.body) else {
                return Self.response(status: 400, body: Data("{}".utf8))
            }
            await pairing.revoke(pairID: body.pairID)
            return Self.response(status: 200, body: Data("{}".utf8))

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
        case ("GET", let path) where path.hasPrefix("/v1/dsh/activity/"):
            let encoded = String(path.dropFirst("/v1/dsh/activity/".count))
            guard let sessionID = encoded.removingPercentEncoding, !sessionID.isEmpty else {
                return Self.response(status: 400, body: Data("{}".utf8))
            }
            struct Activity: Encodable {
                let label: String
                let since: Double
            }
            let body: Data
            if let activity = dshSessions.currentActivity(sessionID: sessionID) {
                body = (try? JSONEncoder().encode(Activity(
                    label: activity.label,
                    since: activity.at.timeIntervalSince1970
                ))) ?? Data("{}".utf8)
            } else {
                body = Data("{}".utf8)
            }
            return Self.response(status: 200, body: body)
        case ("GET", "/v1/dsh/questions"):
            guard dshBridge.isConfigured else {
                return Self.response(status: 200, body: Data("[]".utf8))
            }
            let questions = (try? await dshBridge.questions()) ?? []
            return Self.response(status: 200, body: (try? JSONEncoder().encode(questions)) ?? Data("[]".utf8))
        case ("POST", "/v1/dsh/answer"):
            struct Payload: Decodable {
                let id: String
                let answers: [DSHQuestionAnswer.Item]
            }
            guard let payload = try? JSONDecoder().decode(Payload.self, from: request.body) else {
                return Self.response(status: 400, body: Data("{}".utf8))
            }
            do {
                try await dshBridge.answer(DSHQuestionAnswer(id: payload.id, answers: payload.answers))
                return Self.response(status: 200, body: Data("{\"ok\":true}".utf8))
            } catch {
                return Self.response(status: 409, body: Data("{}".utf8))
            }
        case ("POST", "/v1/approvals"):
            struct Create: Decodable {
                let agent: String?
                let sessionId: String?
                let title: String
                let detail: String?
            }
            guard let payload = try? JSONDecoder().decode(Create.self, from: request.body),
                  !payload.title.isEmpty else {
                return Self.response(status: 400, body: Data("{}".utf8))
            }
            let id = UUID().uuidString
            externalApprovals.append(ExternalApproval(
                id: id,
                agent: payload.agent ?? "claude",
                sessionId: payload.sessionId,
                title: payload.title,
                detail: payload.detail,
                createdAt: Date(),
                status: "pending"
            ))
            if let data = try? JSONEncoder().encode(["id": id]) {
                return Self.response(status: 200, body: data)
            }
            return Self.response(status: 500, body: Data("{}".utf8))

        case ("GET", let path) where path.hasPrefix("/v1/approvals/"):
            let id = String(path.dropFirst("/v1/approvals/".count))
            guard let item = externalApprovals.first(where: { $0.id == id }) else {
                return Self.response(status: 404, body: Data("{}".utf8))
            }
            return Self.response(status: 200, body: (try? JSONEncoder().encode(["status": item.status])) ?? Data("{}".utf8))

        case ("POST", let path) where path.hasPrefix("/v1/approvals/") && path.hasSuffix("/decide"):
            let id = String(path.dropFirst("/v1/approvals/".count).dropLast("/decide".count))
            struct Decide: Decodable { let decision: String }
            guard let payload = try? JSONDecoder().decode(Decide.self, from: request.body),
                  let index = externalApprovals.firstIndex(where: { $0.id == id }) else {
                return Self.response(status: 404, body: Data("{}".utf8))
            }
            externalApprovals[index].status = payload.decision == "allow" ? "approved" : "denied"
            return Self.response(status: 200, body: Data("{}".utf8))

        case ("GET", "/v1/dsh/approvals"):
            struct Response: Encodable {
                let available: Bool
                let pending: [DSHRemoteApproval]
            }
            // 外部通道（Claude hooks 等）的待审也并进来，手机端一套 UI 处理。
            let external = externalApprovals
                .filter { $0.status == "pending" }
                .map { item in
                    DSHRemoteApproval(
                        id: item.id,
                        sessionId: item.sessionId,
                        toolName: item.agent,
                        callId: nil,
                        reason: item.title,
                        // 标题 + 参数一起给手机，否则卡片上只有一个 JSON 片段
                        displayReason: item.detail.map { "\(item.title)\n\($0)" } ?? item.title,
                        createdAt: ISO8601DateFormatter().string(from: item.createdAt)
                    )
                }
            guard dshBridge.isConfigured else {
                return Self.response(status: 200, body: try JSONEncoder().encode(Response(available: !external.isEmpty, pending: external)))
            }
            do {
                // 这是 iPhone 发起的轮询，只有它能代表「手机在线」；
                // 桥接靠这个标记决定要不要扣住桌面审批卡。
                let approvals = try await dshBridge.pending(source: "phone")
                return Self.response(status: 200, body: try JSONEncoder().encode(Response(available: true, pending: approvals + external)))
            } catch {
                return Self.response(status: 200, body: try JSONEncoder().encode(Response(available: true, pending: external)))
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
            // 外部通道（Claude hooks）的审批也走这个入口，手机端不必区分来源。
            if let index = externalApprovals.firstIndex(where: { $0.id == decision.id }) {
                externalApprovals[index].status = decision.decision == "allow" ? "approved" : "denied"
                return Self.response(status: 200, body: Data("{}".utf8))
            }
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
        case ("GET", "/v1/ideas"):
            guard let store else {
                return Self.response(status: 503, body: Data("{}".utf8))
            }
            let ideas = store.syncSnapshot()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return Self.response(status: 200, body: (try? encoder.encode(ideas)) ?? Data("[]".utf8))
        case ("POST", "/v1/ideas/delete"):
            guard let store else {
                return Self.response(status: 503, body: Data("{}".utf8))
            }
            struct DeleteRequest: Decodable { let id: UUID }
            guard let payload = try? JSONDecoder().decode(DeleteRequest.self, from: request.body) else {
                return Self.response(status: 400, body: Data("{}".utf8))
            }
            _ = store.delete(payload.id)
            return Self.response(status: 200, body: Data("{}".utf8))
        case ("POST", "/v1/push/token"):
            // 手机的 APNs device token。Mac 用它直接向苹果推送，不需要服务端。
            struct PushToken: Decodable {
                let token: String
                let environment: String?
                let diagnostics: [String: Int]?
            }
            guard let report = try? JSONDecoder().decode(PushToken.self, from: request.body),
                  report.token.count >= 32 else {
                return Self.response(status: 400, body: Data("{}".utf8))
            }
            UserDefaults.standard.set(report.token, forKey: "FlowCue.pushDeviceToken")
            if let environment = report.environment {
                UserDefaults.standard.set(environment, forKey: "FlowCue.pushEnvironment")
            }
            // 手机的实时通知设置：没声音时先看这几项。
            if let diagnostics = report.diagnostics {
                for (key, value) in diagnostics {
                    UserDefaults.standard.set(value, forKey: "FlowCue.pushDiag.\(key)")
                }
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
