import Foundation
import Network

/// 本地中继 stub：只做「按 pair 转发」和「对端不在就报错」两件事。
///
/// 它不解析加密信封，也不需要 TLS——目的是在没有任何云账号的情况下
/// 把手机 ↔ 中继 ↔ Mac 的协议跑通；之后换成 Cloudflare / VPS 时只替换传输层。
///
/// 帧格式：4 字节大端长度 + JSON。
/// 首帧是握手：`{"role":"mac"|"ios","pair":"..."}`。
public final class RemoteRelayStub: @unchecked Sendable {
    public enum Role: String, Sendable { case mac, ios }

    private let queue = DispatchQueue(label: "flowcue.relay.stub")
    private var listener: NWListener?
    private var peers: [String: [Role: NWConnection]] = [:]
    public private(set) var port: UInt16 = 0

    public init() {}

    /// 绑定系统分配的端口（测试用，避免端口复用冲突）。
    public func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.port = listener.port?.rawValue ?? 0
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func start(onPreferredPort preferred: UInt16 = 47830) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: preferred)!)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.port = listener.port?.rawValue ?? 0
            }
            if case .failed(let error) = state {
                self?.lastError = error.localizedDescription
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public private(set) var lastError: String?

    public func stop() {
        listener?.cancel()
        listener = nil
        queue.sync {
            peers.values.flatMap { $0.values }.forEach { $0.cancel() }
            peers = [:]
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveFrame(on: connection) { [weak self] frame in
            guard let self,
                  let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
                  let roleRaw = object["role"] as? String,
                  let role = Role(rawValue: roleRaw),
                  let pair = object["pair"] as? String else {
                connection.cancel()
                return
            }
            self.register(connection, pair: pair, role: role)
        }
    }

    private func register(_ connection: NWConnection, pair: String, role: Role) {
        peers[pair, default: [:]][role] = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.drop(pair: pair, role: role) }
            if case .cancelled = state { self?.drop(pair: pair, role: role) }
        }
        pump(pair: pair, role: role, connection: connection)
    }

    private func drop(pair: String, role: Role) {
        queue.async { [weak self] in
            self?.peers[pair]?[role] = nil
        }
    }

    private func pump(pair: String, role: Role, connection: NWConnection) {
        receiveFrame(on: connection) { [weak self] frame in
            guard let self else { return }
            let target: Role = role == .mac ? .ios : .mac
            if let peer = self.peers[pair]?[target] {
                self.sendFrame(frame, on: peer)
            } else {
                let offline = Data(#"{"error":"mac_offline"}"#.utf8)
                self.sendFrame(offline, on: connection)
            }
            self.pump(pair: pair, role: role, connection: connection)
        }
    }

    // MARK: 帧

    private func receiveFrame(on connection: NWConnection, handler: @escaping (Data) -> Void) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, isComplete, error in
            guard let self, let header, header.count == 4, error == nil else {
                if isComplete { connection.cancel() }
                return
            }
            let length = header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            guard length > 0, length < 1_048_576 else {
                connection.cancel()
                return
            }
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { body, _, _, error in
                guard let body, body.count == Int(length), error == nil else {
                    connection.cancel()
                    return
                }
                handler(body)
            }
        }
    }

    private func sendFrame(_ payload: Data, on connection: NWConnection) {
        var header = UInt32(payload.count).bigEndian
        let headerData = Data(bytes: &header, count: 4)
        connection.send(content: headerData + payload, completion: .contentProcessed { _ in })
    }
}
