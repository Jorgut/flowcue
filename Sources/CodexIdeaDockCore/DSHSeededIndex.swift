import Foundation

/// 记录哪些 DSH 会话是「安装时自带的示例」（日志头里的 isSeeded）。
///
/// 判断只能读会话头，而读头要解压日志——放进列表路径会把 58 个日志全解压。
/// 所以这里做一次性索引：启动后后台扫描未知会话，结果持久化，之后过滤是纯内存操作。
public enum DSHSeededIndex {
    private static let defaultsKey = "FlowCue.dshSeededIDs"

    public static func seededIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
    }

    /// 后台补扫：只处理还没登记过的会话，扫完写回。
    public static func refresh(sessionsDirectory: URL, sessionIDs: [String]) {
        guard !sessionIDs.isEmpty else { return }
        var known = seededIDs()
        let knownAll = Set(UserDefaults.standard.stringArray(forKey: defaultsKey + ".all") ?? [])
        let unknown = sessionIDs.filter { !knownAll.contains($0) }
        guard !unknown.isEmpty else { return }

        var scanned = knownAll
        for id in unknown {
            scanned.insert(id)
            guard let log = logURL(sessionsDirectory: sessionsDirectory, sessionID: id) else { continue }
            guard let firstLine = firstLine(of: log),
                  let object = try? JSONSerialization.jsonObject(with: firstLine) as? [String: Any] else { continue }
            if (object["isSeeded"] as? Bool) == true { known.insert(id) }
        }
        UserDefaults.standard.set(Array(known), forKey: defaultsKey)
        UserDefaults.standard.set(Array(scanned), forKey: defaultsKey + ".all")
    }

    private static func logURL(sessionsDirectory: URL, sessionID: String) -> URL? {
        let projects = (try? FileManager.default.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for project in projects {
            let candidate = project
                .appendingPathComponent(sessionID)
                .appendingPathComponent("session.v4.jsonl.zstd")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// 只解压到第一行：会话头。
    private static func firstLine(of url: URL) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["zstd", "-dc", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        defer { try? pipe.fileHandleForReading.close() }
        var buffer = Data()
        while buffer.count < 65_536 {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                process.terminate()
                return buffer[..<newline]
            }
        }
        process.terminate()
        return buffer.isEmpty ? nil : buffer
    }
}
