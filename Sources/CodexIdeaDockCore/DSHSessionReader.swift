import Foundation

/// Reads local DSH session logs without requiring the DSH plugin. Only text
/// messages are exposed; reasoning, tool calls, and tool output stay local.
public struct DSHSessionReader: Sendable {
    private let sessionsDirectory: URL
    private let projectionCacheDirectory: URL

    public init(
        sessionsDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".dsh/sessions"),
        projectionCacheDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".dsh/storages/session_projcache/sessions")
    ) {
        self.sessionsDirectory = sessionsDirectory
        self.projectionCacheDirectory = projectionCacheDirectory
    }

    public func sessions(limit: Int = 30) -> [DSHSessionSnapshot] {
        guard let projects = try? FileManager.default.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [DSHSessionSnapshot] = []
        for project in projects where (try? project.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            guard let sessionDirs = try? FileManager.default.contentsOfDirectory(
                at: project,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for session in sessionDirs where session.lastPathComponent.hasPrefix("session-") {
                let log = session.appendingPathComponent("session.v4.jsonl.zstd")
                guard FileManager.default.fileExists(atPath: log.path) else { continue }
                let date = (try? log.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let id = session.lastPathComponent
                let cached = cachedMetadata(sessionID: id)
                found.append(DSHSessionSnapshot(
                    id: id,
                    title: cached?.title ?? Self.projectName(project.lastPathComponent),
                    projectDirectory: cached?.cwd ?? Self.decodeProjectPath(project.lastPathComponent),
                    updatedAt: date
                ))
            }
        }
        return Array(found.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
    }

    public func subagents(ofParent parentID: String, limit: Int = 30) -> [DSHSessionSnapshot] {
        guard let projects = try? FileManager.default.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var found: [DSHSessionSnapshot] = []
        for project in projects {
            guard let sessionDirs = try? FileManager.default.contentsOfDirectory(
                at: project,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for session in sessionDirs where !session.lastPathComponent.hasPrefix("session-") {
                let log = session.appendingPathComponent("session.v4.jsonl.zstd")
                guard FileManager.default.fileExists(atPath: log.path) else { continue }
                guard let parent = headerValue(logURL: log, key: "parentSession") as? String, parent == parentID else { continue }
                let date = (try? log.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let id = session.lastPathComponent
                let cached = cachedMetadata(sessionID: id)
                found.append(DSHSessionSnapshot(
                    id: id,
                    title: cached?.title ?? "Subagent",
                    projectDirectory: cached?.cwd ?? Self.decodeProjectPath(project.lastPathComponent),
                    updatedAt: date,
                    isSubagent: true,
                    parentSessionID: parent
                ))
            }
        }
        return Array(found.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
    }

    private func headerValue(logURL: URL, key: String) -> Any? {
        guard let data = Self.decompress(path: logURL.path, maxBytes: 32_000) else { return nil }
        guard let first = data.split(separator: UInt8(ascii: "\n")).first,
              let object = try? JSONSerialization.jsonObject(with: Data(first)) as? [String: Any] else { return nil }
        return object[key]
    }

    private func cachedMetadata(sessionID: String) -> (cwd: String, title: String?)? {
        let url = projectionCacheDirectory.appendingPathComponent("\(sessionID).json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let record = root["record"] as? [String: Any],
              let identity = record["identity"] as? [String: Any],
              let cwd = identity["cwd"] as? String, !cwd.isEmpty else { return nil }
        var title: String?
        if let rows = record["rows"] as? [String: Any],
           let titleRow = rows["title"] as? [String: Any],
           let value = titleRow["val"] as? String, !value.isEmpty {
            title = value
        }
        return (cwd, title)
    }

    public func messages(sessionID: String, limit: Int = 100) -> [RemoteConversationMessage] {
        guard let log = logURL(sessionID: sessionID) else { return [] }
        guard let data = Self.decompress(path: log.path, maxBytes: 24_000_000) else { return [] }
        var result: [RemoteConversationMessage] = []
        var title: String?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            let time = (object["time"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            switch type {
            case "session/title":
                if let payload = object["data"] as? [String: Any], let value = payload["title"] as? String, !value.isEmpty {
                    title = value
                }
            case "user/message":
                guard let payload = object["data"] as? [String: Any],
                      let content = payload["content"] as? [[String: Any]] else { continue }
                let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty && !Self.isSyntheticUserMessage(text) {
                    result.append(RemoteConversationMessage(id: "u-\(result.count)", role: "user", text: String(text.prefix(20_000)), timestamp: time))
                }
            case "assistant/message":
                guard let payload = object["data"] as? [String: Any],
                      let message = payload["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]] else { continue }
                let text = content.compactMap { item -> String? in
                    guard item["type"] as? String == "text", let value = item["text"] as? String else { return nil }
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }.joined(separator: "\n")
                if !text.isEmpty {
                    result.append(RemoteConversationMessage(id: "a-\(result.count)", role: "assistant", text: String(text.prefix(20_000)), timestamp: time))
                }
            default:
                break
            }
        }
        return Array(result.suffix(limit))
    }

    public func title(sessionID: String) -> String? {
        guard let log = logURL(sessionID: sessionID),
              let data = Self.decompress(path: log.path, maxBytes: 256_000) else { return nil }
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "session/title",
                  let payload = object["data"] as? [String: Any],
                  let title = payload["title"] as? String, !title.isEmpty else { continue }
            return title
        }
        return nil
    }

    private static func isSyntheticUserMessage(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("<system-reminder>")
            || trimmed.hasPrefix("Current runtime context. This snapshot")
            || trimmed.hasPrefix("The available skill catalog changed")
            || trimmed.hasPrefix("<environment_context>")
            || trimmed.contains("<compacted-summary>")
            || trimmed.contains("This is an automatically generated checkpoint")
            || trimmed.contains("Time sampled while preparing turn")
    }

    private func logURL(sessionID: String) -> URL? {
        guard let projects = try? FileManager.default.contentsOfDirectory(at: sessionsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        for project in projects {
            let candidate = project.appendingPathComponent(sessionID).appendingPathComponent("session.v4.jsonl.zstd")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private static func projectName(_ raw: String) -> String {
        var value = raw
        if value.hasPrefix("--") { value.removeFirst(2) }
        if value.hasSuffix("--") { value.removeLast(2) }
        value = value.replacingOccurrences(of: "~0020", with: " ")
        if let last = value.split(separator: "-").last, !last.isEmpty { return String(last) }
        return value.isEmpty ? "DSH session" : value
    }

    private static func decodeProjectPath(_ raw: String) -> String {
        var value = raw
        if value.hasPrefix("--") { value.removeFirst(2) }
        if value.hasSuffix("--") { value.removeLast(2) }
        return value.replacingOccurrences(of: "~0020", with: " ")
    }

    private static func decompress(path: String, maxBytes: Int) -> Data? {
        let candidates = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]
        guard let zstd = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zstd)
        process.arguments = ["-dc", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readData(ofLength: maxBytes)
        if process.isRunning { process.terminate() }
        return data
    }
}
