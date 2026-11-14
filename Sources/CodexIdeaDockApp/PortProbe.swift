import Foundation
import Network

/// 本机端口探测：用于判断 DSH 桥是否在监听。
enum PortProbe {
    static func isOpen(host: String = "127.0.0.1", port: UInt16, timeout: TimeInterval = 0.4) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        final class Box: @unchecked Sendable { var reachable = false }
        let box = Box()

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                box.reachable = true
                semaphore.signal()
            case .failed, .cancelled:
                semaphore.signal()
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .utility))
        _ = semaphore.wait(timeout: .now() + timeout)
        connection.cancel()
        return box.reachable
    }
}
