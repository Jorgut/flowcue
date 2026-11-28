import Foundation
import Network

/// Mac 侧的中继客户端：注册、保持 WebSocket、把收到的加密请求交给
/// 同一套 `dispatchRemote` 路由，再把响应加密发回去。
///
/// 它不解析业务数据——解密只发生在拿到 pair 会话之后。
///
/// 状态规则和 iPhone 端一致：**只有 WebSocket 确认（收到帧或 app/pong
/// 心跳回显）之后才算 `.online`**。`resume()` 成功不代表连上了，之前
/// 在这里直接标 online，中继/网络半死时设置页会一直显示「中继在线」。
public final class RemoteRelayClient: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case idle, connecting, online, offline(reason: String)

        public var isOnline: Bool { if case .online = self { return true } else { return false } }
        public var reason: String? { if case .offline(let reason) = self { return reason } else { return nil } }
    }

    private let relayURL: URL
    private let macID: String
    private let server: LANRemoteServer
    private let queue = DispatchQueue(label: "flowcue.remote.relay")
    private var task: URLSessionWebSocketTask?
    private var stopped = true
    private var macToken: String?
    private var reconnectAttempt = 0
    private var registering = false
    private var generation = 0
    private var connectingSince: Date?
    private var reconnectWork: DispatchWorkItem?
    private var handshakeWork: DispatchWorkItem?
    private var heartbeatDeadline: Date?
    private var _state: State = .idle
    /// 串行处理加密帧：每个 frame 的解密/路由/回包必须按到达顺序执行。
    /// 之前每帧起一个独立 Task，Task 调度可能让 seq 4 先于 seq 3 解密，
    /// 3 就会被当成 replay 丢掉，手机侧表现就是请求超时/消息未送达。
    private var frameChain: Task<Void, Never>?
    private var mailboxPoll: Task<Void, Never>?
    #if DEBUG
    private var deviceFixtureDidSend = false
    #endif
    private var cloudKitPoll: Task<Void, Never>?
    /// POST 幂等缓存：客户端重试复用同一个 request id，Mac 直接回放上次响应，
    /// 避免「第一次其实已执行、客户端超时后重试」造成重复消息/turn。
    private var postResponses: [String: (response: RemoteResponse, at: Date)] = [:]

    /// 线程安全的对外状态；UI 每几秒读一次即可。
    public var state: State { queue.sync { _state } }
    public var onStateChange: ((State) -> Void)?
    /// 设置页读取中继在线状态。
    public nonisolated(unsafe) static weak var shared: RemoteRelayClient?
    /// Mac 需要弹出批准界面（pairID, 6 位码）。UI 由 AppDelegate 提供。
    public var onPairRequest: ((String, String) -> Void)?
    public var onPairRejected: ((String, String) -> Void)?


    public init(relayURL: URL, macID: String, server: LANRemoteServer) {
        self.relayURL = relayURL
        self.macID = macID
        self.server = server
        self.macToken = UserDefaults.standard.string(forKey: "FlowCue.remoteMacToken")
    }

    // MARK: 启动

    public func start() {
        queue.async { [weak self] in
            guard let self, self.stopped else { return }
            self.stopped = false
            self.reconnectAttempt = 0
            self.setState(.connecting)
            self.registerThenConnect()
            self.startWatchdog()
            self.startPairPolling()
            self.startTestMailbox()
            self.startCloudKitChat()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.generation += 1
            self.registering = false
            self.reconnectWork?.cancel(); self.reconnectWork = nil
            self.handshakeWork?.cancel(); self.handshakeWork = nil
            self.mailboxPoll?.cancel(); self.mailboxPoll = nil
            self.cloudKitPoll?.cancel(); self.cloudKitPoll = nil
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
            self.setState(.idle)
        }
    }

    /// 轮询待批准配对：不依赖 WebSocket，避免半死连接导致弹窗不出现。
    private func startPairPolling() {
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.stopped else { return }
            Task { await self.pollPendingPairs() }
            self.startPairPolling()
        }
    }

    private func pollPendingPairs() async {
        var components = URLComponents(url: relayURL.appendingPathComponent("v1/remote/pair/pending"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "mac", value: macID)]
        guard let url = components?.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["pending"] as? [[String: Any]] else { return }
        for item in list {
            guard let pairID = item["pairID"] as? String,
                  let code = item["code"] as? String,
                  let keyBase64 = item["phonePublicKey"] as? String,
                  let phoneKey = Data(base64Encoded: keyBase64) else { continue }
            let phoneID = item["phoneID"] as? String
            let phoneName = item["phoneName"] as? String
            await notifyRelay(path: "v1/remote/pair/mark", pairID: pairID)
            do {
                _ = try await server.pairing.request(
                    code: code,
                    phonePublicKey: phoneKey,
                    pairID: pairID,
                    phoneID: phoneID,
                    phoneName: phoneName
                )
                await MainActor.run { self.onPairRequest?(pairID, code) }
            } catch {
                await MainActor.run { self.onPairRejected?(pairID, String(describing: error)) }
            }
        }
    }

    // MARK: 注册与 WebSocket

    /// 每次都重新注册：中继的 Durable Object 可能被部署重置，
    /// 只靠首次注册的话公钥会丢失，手机端就会「密钥协商失败」。
    private func registerThenConnect() {
        // 同一时间只允许一个注册在飞：两次注册会互相轮换 token，
        // 后完成的旧注册会把新 token 覆盖掉，随后 WS 401 循环。
        guard !registering else { return }
        registering = true
        Task { [weak self] in
            guard let self else { return }
            // 公钥来自 actor，必须在异步上下文里取
            let publicKey = await self.server.pairing.publicKey
            await self.performRegister(publicKey: publicKey)
        }
    }

    private func performRegister(publicKey: Data) async {
        guard var components = URLComponents(url: relayURL.appendingPathComponent("v1/remote/mac/register"), resolvingAgainstBaseURL: false) else {
            queue.async { self.registering = false; self.scheduleReconnect(reason: "bad url") }
            return
        }
        components.queryItems = [URLQueryItem(name: "mac", value: macID)]
        guard let url = components.url else {
            queue.async { self.registering = false }
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONEncoder().encode([
            "macID": macID,
            "publicKey": publicKey.base64EncodedString()
        ])
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = object["macToken"] as? String else {
                queue.async {
                    self.registering = false
                    self.scheduleReconnect(reason: "register failed")
                }
                return
            }
            queue.async {
                self.registering = false
                self.macToken = token
                UserDefaults.standard.set(token, forKey: "FlowCue.remoteMacToken")
                self.openSocket()
            }
        } catch {
            queue.async {
                self.registering = false
                self.scheduleReconnect(reason: error.localizedDescription)
            }
        }
    }

    /// 只能在 queue 上调用。
    private func openSocket() {
        guard !stopped else { return }
        guard let macToken else {
            scheduleReconnect(reason: "no token")
            return
        }
        var components = URLComponents(url: relayURL, resolvingAgainstBaseURL: false)
        components?.scheme = relayURL.scheme == "https" ? "wss" : "ws"
        components?.path = "/v1/remote/ws"
        components?.queryItems = [
            URLQueryItem(name: "role", value: "mac"),
            URLQueryItem(name: "mac", value: macID),
            URLQueryItem(name: "token", value: macToken),
        ]
        guard let url = components?.url else {
            scheduleReconnect(reason: "bad url")
            return
        }

        generation += 1
        let gen = generation
        handshakeWork?.cancel(); handshakeWork = nil
        task?.cancel(with: .goingAway, reason: nil)
        // 用 URLSessionWebSocketTask：Network.framework 的 WebSocket 在这里
        // 会长时间停在 preparing，握手不完成。
        let socket = URLSession.shared.webSocketTask(with: url)
        task = socket
        connectingSince = Date()
        setState(.connecting)
        socket.resume()

        // URLSession 没有 ready 回调，Workers 对 WebSocket ping 控制帧的
        // 回复在 URLSession 上也不可靠；改用中继回显的 app/pong 确认。
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, gen == self.generation, !self.stopped,
                  self._state == .connecting else { return }
            self.ping()
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard gen == self.generation, self._state == .connecting else { return }
            self.handleDrop("连接超时。")
        }
        handshakeWork = timeout
        queue.asyncAfter(deadline: .now() + 15, execute: timeout)
        receiveLoop(gen: gen, socket: socket)
    }

    private func receiveLoop(gen: Int, socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard gen == self.generation, !self.stopped else { return }
                switch result {
                case .failure(let error):
                    self.handleDrop(Self.describe(error))
                case .success(let message):
                    // 收到帧本身就是最可靠的在线证据。
                    self.connectingSince = nil
                    self.reconnectAttempt = 0
                    self.heartbeatDeadline = nil
                    self.setState(.online)
                    switch message {
                    case .data(let data): self.handleFrame(data)
                    case .string(let text): self.handleFrame(Data(text.utf8))
                    @unknown default: break
                    }
                    self.receiveLoop(gen: gen, socket: socket)
                }
            }
        }
    }

    /// 只能在 queue 上调用。
    private func scheduleReconnect(reason: String) {
        guard !stopped, reconnectWork == nil else { return }
        connectingSince = nil
        reconnectAttempt = min(reconnectAttempt + 1, 6)
        let delay = min(pow(2.0, Double(reconnectAttempt)) * 0.5, 30)
        setState(.offline(reason: reason))
        NSLog("[FlowCue Remote][Mac] offline (%@), retry in %.0fs", reason, delay)
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.reconnectWork = nil
            // 重新注册：中继可能已经重置，旧 token 不认了。
            self.registerThenConnect()
        }
        reconnectWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 连接已失效：取消 socket、标离线、安排重连。只能在 queue 上调用。
    private func handleDrop(_ reason: String) {
        guard !stopped else { return }
        generation += 1
        handshakeWork?.cancel(); handshakeWork = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connectingSince = nil
        scheduleReconnect(reason: reason)
    }

    private func startWatchdog() {
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, !self.stopped else { return }
            switch self._state {
            case .online:
                self.ping()
            case .connecting:
                if let since = self.connectingSince, Date().timeIntervalSince(since) > 12 {
                    self.handleDrop("连接超时。")
                }
            case .offline, .idle:
                if self.reconnectWork == nil { self.scheduleReconnect(reason: "watchdog") }
            }
            self.startWatchdog()
        }
    }

    /// 半死连接的主动探活：发 app/ping，中继立刻回 app/pong。
    private func ping() {
        guard let socket = task else {
            handleDrop("连接已断开。")
            return
        }
        let gen = generation
        heartbeatDeadline = Date().addingTimeInterval(20)
        socket.send(.string(#"{"type":"app/ping"}"#)) { [weak self] error in
            guard let self, let error else { return }
            self.queue.async {
                guard gen == self.generation, !self.stopped else { return }
                self.handleDrop("心跳发送失败：\(error.localizedDescription)")
            }
        }
        queue.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, gen == self.generation, !self.stopped else { return }
            guard let deadline = self.heartbeatDeadline, Date() >= deadline else { return }
            self.handleDrop("心跳超时。")
        }
    }

    // MARK: 帧处理

    /// 写 ~/.flowcue/relay.log：open 启动时 NSLog 不进系统日志，排查全靠它。
    private func log(_ message: String) {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".flowcue")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("relay.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? line.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// 只能在 queue 上调用。
    private func handleFrame(_ data: Data) {
        // 控制帧（明文）：pair/request 等
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = object["type"] as? String {
            if type == "app/pong" {
                heartbeatDeadline = nil
                connectingSince = nil
                reconnectAttempt = 0
                setState(.online)
                return
            }
            if type == "error" { return }
            log("control frame: \(type)")
            if type == "pair/request",
               let pairID = object["pairID"] as? String,
               let code = object["code"] as? String,
               let keyBase64 = object["phonePublicKey"] as? String,
               let phoneKey = Data(base64Encoded: keyBase64) {
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        _ = try await self.server.pairing.request(
                            code: code,
                            phonePublicKey: phoneKey,
                            pairID: pairID,
                            phoneID: object["phoneID"] as? String,
                            phoneName: object["phoneName"] as? String
                        )
                        self.log("pair request accepted, code=\(code), showing dialog")
                        await MainActor.run {
                            self.onPairRequest?(pairID, code)
                        }
                    } catch {
                        self.log("pair request rejected: \(error)")
                        await MainActor.run {
                            self.onPairRejected?(pairID, String(describing: error))
                        }
                    }
                }
            }
            return
        }

        guard let envelope = try? JSONDecoder().decode(RemoteEnvelope.self, from: data) else {
            NSLog("[FlowCue Remote] envelope decode failed: %@",
                  String(decoding: data.prefix(60), as: UTF8.self))
            return
        }
        // 串行链：保证解密/路由顺序和帧到达顺序一致。
        let previous = frameChain
        frameChain = Task { [weak self] in
            _ = await previous?.value
            guard let self else { return }
            await self.processEnvelope(envelope)
        }
    }

    private func processEnvelope(_ envelope: RemoteEnvelope) async {
        guard let (request, response) = await dispatchEnvelope(envelope) else { return }
        await sendResponse(response, requestID: request.id, pairID: envelope.pair, path: request.path)
    }

    private func dispatchEnvelope(_ envelope: RemoteEnvelope, expectedID: String? = nil) async -> (RemoteRequest, RemoteResponse)? {
        let plaintext: Data
        do {
            plaintext = try await server.pairing.openEnvelope(envelope)
        } catch {
            NSLog("[FlowCue Remote] decrypt failed: %@", String(describing: error))
            return nil
        }
        guard let request = try? JSONDecoder().decode(RemoteRequest.self, from: plaintext) else {
            NSLog("[FlowCue Remote] bad request payload")
            return nil
        }
        if let expectedID, request.id.lowercased() != expectedID { return nil }
        #if DEBUG
        if expectedID != nil, let fixtureResponse = deviceFixtureResponse(for: request) {
            return (request, fixtureResponse)
        }
        #endif
        if request.method == "POST", let cached = postResponses[request.id] {
            log("idempotent POST replay \(request.path) id=\(request.id)")
            return (request, cached.response)
        }
        let started = Date()
        let result = await server.dispatchRemote(
            method: request.method,
            path: request.path,
            headers: request.headers,
            body: request.body,
            authenticated: true
        )
        log("\(request.method) \(request.path) → \(result.status)")
        NSLog("[FlowCue Remote] %@ %@ → %d (%.1fs)",
              request.method, request.path, result.status,
              Date().timeIntervalSince(started))
        let response = RemoteResponse(id: request.id, status: result.status, body: result.body)
        if request.method == "POST", (response.body?.count ?? 0) < 1_000_000 {
            let cutoff = Date().addingTimeInterval(-600)
            postResponses = postResponses.filter { $0.value.at > cutoff }
            postResponses[request.id] = (response, Date())
            if postResponses.count > 256 {
                let oldest = postResponses.min { $0.value.at < $1.value.at }?.key
                if let oldest { postResponses.removeValue(forKey: oldest) }
            }
        }
        return (request, response)
    }

    private func startCloudKitChat() {
        cloudKitPoll = Task { @MainActor [weak self] in
            guard let macID = self?.macID else { return }
            var selected = CloudKitChatMailbox.configured(for: macID)
            #if DEBUG
            let environment = ProcessInfo.processInfo.environment
            if environment["FLOWCUE_TEST_HTTPS_READ_ONLY"] == "1",
               let testSession = environment["FLOWCUE_TEST_HTTPS_DSH_SESSION"], !testSession.isEmpty,
               let testMailbox = CloudKitChatMailbox() {
                selected = testMailbox
            }
            #endif
            guard let mailbox = selected else { return }
            var seen: [UUID: Date] = [:]
            var pendingReceipts: [UUID: Data] = [:]
            var prepared = false
            while !Task.isCancelled, let self {
                do {
                    if !prepared {
                        try await mailbox.prepare()
                        prepared = true
                    }
                    for (id, receipt) in pendingReceipts {
                        if try await mailbox.read(.receipt, id: id) == nil {
                            try await mailbox.create(.receipt, id: id, payload: receipt)
                        }
                        pendingReceipts.removeValue(forKey: id)
                    }
                    let cutoff = Date().addingTimeInterval(-120)
                    seen = seen.filter { $0.value >= cutoff }
                    for (id, frame) in try await mailbox.pendingRequests(excluding: Set(seen.keys), newerThan: cutoff) {
                        try Task.checkCancellation()
                        // Only the successful creator may dispatch. A lost
                        // claim acknowledgment must never trigger execution.
                        let claimed = try await mailbox.claim(id)
                        seen[id] = Date()
                        guard claimed else { continue }
                        guard let receipt = await self.processCloudKitClaim(frame, id: id) else { continue }
                        pendingReceipts[id] = receipt
                        try await mailbox.create(.receipt, id: id, payload: receipt)
                        pendingReceipts.removeValue(forKey: id)
                    }
                } catch {
                    // Pending requests are reloaded on the next poll.
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func processCloudKitClaim(_ frame: Data, id: UUID) async -> Data? {
        guard let envelope = try? JSONDecoder().decode(RemoteEnvelope.self, from: frame) else { return nil }
        return await withCheckedContinuation { continuation in
            queue.async {
                guard !self.stopped, self.cloudKitPoll != nil else {
                    continuation.resume(returning: nil)
                    return
                }
                let previous = self.frameChain
                self.frameChain = Task {
                    _ = await previous?.value
                    guard let (_, response) = await self.dispatchEnvelope(envelope, expectedID: id.uuidString.lowercased()),
                          let plaintext = try? JSONEncoder().encode(response),
                          let sealed = try? await self.server.pairing.sealEnvelope(pairID: envelope.pair, plaintext: plaintext)
                    else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: try? JSONEncoder().encode(sealed))
                }
            }
        }
    }

    #if DEBUG
    private func deviceFixtureResponse(for request: RemoteRequest) -> RemoteResponse? {
        let env = ProcessInfo.processInfo.environment
        guard env["FLOWCUE_TEST_HTTPS_READ_ONLY"] == "1" else { return nil }
        let sessionID = env["FLOWCUE_TEST_HTTPS_DSH_SESSION"]
        if request.method == "GET" {
            if request.path == "/v1/ping" { return nil }
            if ["/v1/agents", "/v1/skills", "/v1/threads"].contains(request.path) {
                return RemoteResponse(id: request.id, status: 200, body: Data("[]".utf8))
            }
            if let sessionID, request.path == "/v1/dsh/sessions" {
                let session = DSHSessionSnapshot(
                    id: sessionID, title: "FlowCue 5G 验收", projectDirectory: "", updatedAt: .now
                )
                return RemoteResponse(id: request.id, status: 200, body: try? JSONEncoder().encode([session]))
            }
            if let sessionID, URLComponents(string: request.path)?.path == "/v1/dsh/sessions/\(sessionID)/messages" {
                return nil
            }
        }
        if request.method == "POST", request.path == "/v1/dsh/send", !deviceFixtureDidSend,
           let sessionID, let text = env["FLOWCUE_TEST_HTTPS_DSH_TEXT"],
           let body = request.body, let message = try? JSONDecoder().decode(DSHRemoteMessage.self, from: body),
           message.sessionId == sessionID, message.text == text, message.requestID == request.id,
           message.images?.isEmpty != false {
            deviceFixtureDidSend = true
            return nil
        }
        return RemoteResponse(id: request.id, status: 405, body: nil)
    }
    #endif

    private func startTestMailbox() {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        guard let address = env["FLOWCUE_TEST_HTTPS_URL"], let base = URL(string: address),
              base.scheme == "https", base.host != nil,
              let token = env["FLOWCUE_TEST_HTTPS_MAC_TOKEN"], !token.isEmpty else { return }
        mailboxPoll = Task { [weak self] in
            while !Task.isCancelled {
                var claim = URLRequest(url: base.appendingPathComponent("prototype/claim"))
                claim.httpMethod = "POST"
                claim.timeoutInterval = 8
                claim.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                if let (data, result) = try? await URLSession.shared.data(for: claim),
                   !Task.isCancelled, let response = result as? HTTPURLResponse, response.statusCode == 200,
                   let id = response.value(forHTTPHeaderField: "x-flowcue-request-id")?.lowercased(),
                   UUID(uuidString: id) != nil,
                   let envelope = try? JSONDecoder().decode(RemoteEnvelope.self, from: data) {
                    await self?.processMailboxClaim(envelope, id: id, base: base, token: token)
                    continue
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        #endif
    }

    private func processMailboxClaim(_ envelope: RemoteEnvelope, id: String, base: URL, token: String) async {
        await withCheckedContinuation { continuation in
            queue.async {
                guard !self.stopped, self.mailboxPoll != nil else {
                    continuation.resume()
                    return
                }
                let previous = self.frameChain
                self.frameChain = Task {
                    defer { continuation.resume() }
                    _ = await previous?.value
                    guard let (_, response) = await self.dispatchEnvelope(envelope, expectedID: id),
                          let plaintext = try? JSONEncoder().encode(response),
                          let sealed = try? await self.server.pairing.sealEnvelope(pairID: envelope.pair, plaintext: plaintext),
                          let data = try? JSONEncoder().encode(sealed),
                          data.count <= 256 * 1024 else { return }
                    var complete = URLRequest(url: base.appendingPathComponent("prototype/complete/\(id)"))
                    complete.httpMethod = "POST"
                    complete.httpBody = data
                    complete.timeoutInterval = 8
                    complete.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    for _ in 0..<2 {
                        if let (_, result) = try? await URLSession.shared.data(for: complete),
                           (result as? HTTPURLResponse)?.statusCode == 200 { return }
                    }
                }
            }
        }
    }

    private func sendResponse(_ response: RemoteResponse, requestID: String, pairID: String, path: String) async {
        guard let encoded = try? JSONEncoder().encode(response) else { return }

        // Cloudflare WebSocket 单帧上限 1MiB。DSH 会话里内联的 base64 截图
        // 会让响应超过上限；超过阈值就拆成多个加密 chunk，手机端按 id 重组。
        if encoded.count > 320_000 {
            let chunkSize = 240_000
            let total = (encoded.count + chunkSize - 1) / chunkSize
            guard total <= 128 else {
                let fallback = RemoteResponse(id: requestID, status: 413, body: Data("response_too_large".utf8))
                if let json = try? JSONEncoder().encode(fallback),
                   let reply = try? await server.pairing.sealEnvelope(pairID: pairID, plaintext: json),
                   let frame = try? JSONEncoder().encode(reply) {
                    queue.async { [weak self] in self?.send(frame) }
                }
                return
            }
            log("chunked response \(path) bytes=\(encoded.count) chunks=\(total)")
            for index in 0..<total {
                let start = index * chunkSize
                let end = min(start + chunkSize, encoded.count)
                let chunk = RemoteChunk(id: requestID, index: index, total: total, data: encoded.subdata(in: start..<end))
                guard let chunkJSON = try? JSONEncoder().encode(chunk),
                      let reply = try? await server.pairing.sealEnvelope(pairID: pairID, plaintext: chunkJSON),
                      let frame = try? JSONEncoder().encode(reply) else { return }
                queue.async { [weak self] in self?.send(frame) }
            }
            return
        }

        guard let reply = try? await server.pairing.sealEnvelope(pairID: pairID, plaintext: encoded),
              let frame = try? JSONEncoder().encode(reply) else { return }
        log("response \(path) frame=\(frame.count) bytes")
        queue.async { [weak self] in self?.send(frame) }
    }

    /// Mac 上点了「允许」。
    public func approvePair(pairID: String) {
        Task { [weak self] in
            guard let self else { return }
            let approval = try? await self.server.pairing.approve(pairID: pairID)
            // 同一台手机重新配对或超过保留上限时，旧 pair 要同步从中继撤掉，
            // 否则旧 socket 还能继续挂着。
            for oldPairID in approval?.replacedPairIDs ?? [] {
                await self.notifyRelay(path: "v1/remote/pair/revoke", pairID: oldPairID)
            }
            await self.notifyRelay(path: "v1/remote/pair/approve", pairID: pairID)
        }
    }

    /// 设置页撤销配对后，让中继关掉对应 socket 并删除记录。
    public func revokePairOnRelay(_ pairID: String) async {
        await notifyRelay(path: "v1/remote/pair/revoke", pairID: pairID)
    }

    /// 配对码无效（过期/已用）时通知中继，手机端才能立即显示原因。
    public func reportPairRejected(pairID: String) async {
        await notifyRelay(path: "v1/remote/pair/reject", pairID: pairID)
    }

    public func denyPair(pairID: String) async {
        await server.pairing.deny(pairID: pairID)
        await notifyRelay(path: "v1/remote/pair/revoke", pairID: pairID)
    }

    private func notifyRelay(path: String, pairID: String) async {
        var components = URLComponents(url: relayURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "mac", value: macID)]
        guard let url = components?.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONEncoder().encode(["pairID": pairID])
        _ = try? await URLSession.shared.data(for: request)
    }

    /// 只能在 queue 上调用。
    private func send(_ data: Data) {
        guard let socket = task else { return }
        let gen = generation
        socket.send(.data(data)) { [weak self] error in
            guard let self, let error else { return }
            self.queue.async {
                // 旧 socket 的回调不能把刚重建好的连接打掉。
                guard gen == self.generation else { return }
                self.handleDrop("发送失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: 工具

    private func setState(_ new: State) {
        guard _state != new else { return }
        _state = new
        NSLog("[FlowCue Remote][Mac] state → %@", String(describing: new))
        onStateChange?(new)
    }

    private static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return "连接超时。"
            case .networkConnectionLost, .notConnectedToInternet: return "网络已断开。"
            case .cancelled: return "连接已取消。"
            default: return "中继连接已断开。"
            }
        }
        return error.localizedDescription
    }
}
