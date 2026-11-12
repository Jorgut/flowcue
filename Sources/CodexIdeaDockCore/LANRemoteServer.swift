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
    private var listener: NWListener?
    private var connections: [UUID: HTTPConnection] = [:]

    public init(
        executorID: UUID,
        pairingCode: String,
        bridge: any CodexBridging,
        ledgerURL: URL,
        sessionsDirectory: URL? = nil,
        dshBridge: DSHBridgeClient = DSHBridgeClient()
    ) throws {
        self.executorID = executorID
        self.pairingCode = pairingCode
        self.bridge = bridge
        self.executor = try RemoteCommandExecutor(executorID: executorID, ledgerURL: ledgerURL, bridge: bridge)
        self.reader = CodexSessionReplyReader(sessionsDirectory: sessionsDirectory ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions"))
        self.dshBridge = dshBridge
    }

    public func start() throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
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

    private func respond(to request: HTTPRequest) async throws -> Data {
        if request.path == "/v1/ping" {
            let payload = ["name": "FlowCue", "version": "1"]
            return Self.response(status: 200, body: try JSONEncoder().encode(payload))
        }
        guard request.headers["authorization"] == "Bearer \(pairingCode)" else {
            return Self.response(status: 401, body: Data("{}".utf8))
        }
        switch (request.method, request.path) {
        case ("GET", "/v1/threads"):
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
            return Self.response(status: 200, body: try JSONEncoder().encode(snapshots))
        case ("GET", "/v1/dsh/approvals"):
            do {
                let approvals = try await dshBridge.pending()
                return Self.response(status: 200, body: try JSONEncoder().encode(approvals))
            } catch DSHBridgeError.notInstalled {
                return Self.response(status: 200, body: Data("[]".utf8))
            } catch {
                return Self.response(status: 503, body: Data("{}".utf8))
            }
        case ("POST", "/v1/dsh/decide"):
            let decision = try JSONDecoder().decode(DSHRemoteDecision.self, from: request.body)
            do {
                try await dshBridge.decide(id: decision.id, decision: decision.decision)
                return Self.response(status: 200, body: Data("{}".utf8))
            } catch {
                return Self.response(status: 409, body: Data("{}".utf8))
            }
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
