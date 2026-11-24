import Foundation
import Network

/// Mac 侧的中继客户端：注册、保持 WebSocket、把收到的加密请求交给
/// 同一套 `dispatchRemote` 路由，再把响应加密发回去。
///
/// 它不解析业务数据——解密只发生在拿到 pair 会话之后。
public final class RemoteRelayClient: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case idle, connecting, online, offline(reason: String)
    }

    private let relayURL: URL
    private let macID: String
    private let server: LANRemoteServer
    private let queue = DispatchQueue(label: "flowcue.remote.relay")
    private var task: URLSessionWebSocketTask?
    private var stopped = false
    private var macToken: String?
    private var reconnectAttempt = 0
    public private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }
    public var onStateChange: ((State) -> Void)?
    /// 设置页读取中继在线状态。
    public nonisolated(unsafe) static weak var shared: RemoteRelayClient?
    /// Mac 需要弹出批准界面（pairID, 6 位码）。UI 由 AppDelegate 提供。
    public var onPairRequest: ((String, String) -> Void)?
    public var onPairRejected: ((String, String) -> Void)?
    private var pendingPair: (pairID: String, code: String, key: Data)?

    public init(relayURL: URL, macID: String, server: LANRemoteServer) {
        self.relayURL = relayURL
        self.macID = macID
        self.server = server
        self.macToken = UserDefaults.standard.string(forKey: "FlowCue.remoteMacToken")
    }

    // MARK: 启动

    public func start() {
        queue.async { [weak self] in
            self?.stopped = false
            self?.registerThenConnect()
            self?.startWatchdog()
        }
    }

    /// 中继部署、休眠或网络切换都会让连接静默失效。
    /// 每 15 秒检查一次，不在线就主动重连。
    private func startWatchdog() {
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, !self.stopped else { return }
            if self.state != .online {
                self.state = .offline(reason: "watchdog")
                self.task?.cancel(with: .goingAway, reason: nil)
                self.task = nil
                self.reconnectAttempt = 0
                self.connect()
            }
            self.startWatchdog()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.stopped = true
            self?.task?.cancel(with: .goingAway, reason: nil)
            self?.task = nil
            self?.state = .idle
        }
    }

    private func registerThenConnect() {
        // 每次都重新注册：中继的 Durable Object 可能被部署重置，
        // 只靠首次注册的话公钥会丢失，手机端就会「密钥协商失败」。
        Task { [weak self] in
            guard let self else { return }
            // 公钥来自 actor，必须在异步上下文里取
            let publicKey = await self.server.pairing.publicKey
            await self.performRegister(publicKey: publicKey)
        }
    }

    private func performRegister(publicKey: Data) async {
        guard var components = URLComponents(url: relayURL.appendingPathComponent("v1/remote/mac/register"), resolvingAgainstBaseURL: false) else {
            scheduleReconnect(reason: "bad url")
            return
        }
        components.queryItems = [URLQueryItem(name: "mac", value: macID)]
        guard let url = components.url else { return }
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
                scheduleReconnect(reason: "register failed")
                return
            }
            macToken = token
            UserDefaults.standard.set(token, forKey: "FlowCue.remoteMacToken")
            queue.async { self.connect() }
        } catch {
            scheduleReconnect(reason: error.localizedDescription)
        }
    }

    // MARK: WebSocket

    private func connect() {
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
        // 用 URLSessionWebSocketTask：Network.framework 的 WebSocket 在这里
        // 会长时间停在 preparing，握手不完成。
        let socket = URLSession.shared.webSocketTask(with: url)
        task = socket
        state = .connecting
        socket.resume()
        receiveLoop()
    }

    private func scheduleReconnect(reason: String) {
        reconnectAttempt = min(reconnectAttempt + 1, 6)
        let delay = pow(2.0, Double(reconnectAttempt)) * 0.5
        state = .offline(reason: reason)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped else { return }
            self.connect()
        }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.state = .offline(reason: error.localizedDescription)
                self.scheduleReconnect(reason: error.localizedDescription)
            case .success(let message):
                self.state = .online
                self.reconnectAttempt = 0
                switch message {
                case .data(let data): self.handleFrame(data)
                case .string(let text): self.handleFrame(Data(text.utf8))
                @unknown default: break
                }
                self.receiveLoop()
            }
        }
    }

    // MARK: 帧处理

    private func handleFrame(_ data: Data) {
        NSLog("[FlowCue Remote] frame in: %d bytes", data.count)
        // 控制帧（明文）：pair/request 等
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = object["type"] as? String {
            if type == "error" { return }
            if type == "pair/request",
               let pairID = object["pairID"] as? String,
               let code = object["code"] as? String,
               let keyBase64 = object["phonePublicKey"] as? String,
               let phoneKey = Data(base64Encoded: keyBase64) {
                pendingPair = (pairID, code, phoneKey)
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        _ = try await self.server.pairing.request(
                            code: code, phonePublicKey: phoneKey, pairID: pairID
                        )
                        await MainActor.run {
                            self.onPairRequest?(pairID, code)
                        }
                    } catch {
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
        Task { [weak self] in
            guard let self else { return }
            guard var session = await self.server.pairing.session(for: envelope.pair) else {
                NSLog("[FlowCue Remote] no session for pair %@", envelope.pair)
                return
            }
            let plaintext: Data
            do {
                plaintext = try session.open(envelope)
            } catch {
                NSLog("[FlowCue Remote] decrypt failed: %@", String(describing: error))
                return
            }
            guard let request = try? JSONDecoder().decode(RemoteRequest.self, from: plaintext) else {
                NSLog("[FlowCue Remote] bad request payload")
                return
            }
            let started = Date()
            let result = await self.server.dispatchRemote(
                method: request.method,
                path: request.path,
                headers: request.headers,
                body: request.body
            )
            NSLog("[FlowCue Remote] %@ %@ → %d (%.1fs)",
                  request.method, request.path, result.status,
                  Date().timeIntervalSince(started))
            let response = RemoteResponse(id: request.id, status: result.status, body: result.body)
            guard let encoded = try? JSONEncoder().encode(response),
                  var reply = try? session.seal(encoded),
                  let frame = try? JSONEncoder().encode(reply) else { return }
            self.send(frame)
        }
    }

    /// Mac 上点了「允许」。
    public func approvePair(pairID: String) {
        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.server.pairing.approve(pairID: pairID)
            await self.notifyRelay(path: "v1/remote/pair/approve", pairID: pairID)
        }
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

    private func send(_ data: Data) {
        task?.send(.data(data)) { _ in }
    }
}
