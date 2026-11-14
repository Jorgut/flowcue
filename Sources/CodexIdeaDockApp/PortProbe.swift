import Foundation
import Network

/// 本机端口探测：用于判断 DSH 桥是否在监听。
enum PortProbe {
    static func isOpen(host: String = "127.0.0.1", port: UInt16, timeout: TimeInterval = 0.4) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        final class Box: @unchecked Sendable { var reachable = false 
    /// 端口是否被占用（尝试 bind，失败即占用）。
    static func isOccupied(port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound != 0
    }
}
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

    /// 端口是否被占用：尝试 bind 到该端口，失败即说明已有人在听。
    static func isOccupied(port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound != 0
    }
}

enum CodexHooks {
    /// hooks 已接入：`~/.codex/hooks.json` 存在，或 config.toml 里登记过。
    static var isInstalled: Bool {
        let home = NSHomeDirectory()
        let hooksFile = home + "/.codex/hooks.json"
        if FileManager.default.fileExists(atPath: hooksFile) { return true }
        let config = home + "/.codex/config.toml"
        guard let text = try? String(contentsOfFile: config, encoding: .utf8) else { return false }
        return text.contains("hooks.json")
    }
}
