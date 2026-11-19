import Foundation

/// 安装 / 检测 Codex 的 Stop hook，并读取它写回的事件。
/// 只做两件事：把一条 `Stop` hook 加进 `~/.codex/hooks.json`（先备份），
/// 以及解析 `~/.flowcue/hook-events.jsonl` 里的事件。
public enum CodexHooks {
    /// 测试可注入的根目录；默认用真实 HOME。
    nonisolated(unsafe) public static var home: URL = URL(fileURLWithPath: NSHomeDirectory())
    public static var hooksFile: URL { home.appendingPathComponent(".codex/hooks.json") }
    public static var scriptFile: URL { home.appendingPathComponent(".flowcue/flowcue-hook.sh") }
    public static var eventsFile: URL { home.appendingPathComponent(".flowcue/hook-events.jsonl") }

    public struct Event: Sendable, Equatable {
        public let type: String
        public let sessionID: String?
        public let cwd: String?
        public let receivedAt: Date
    }

    // MARK: 检测

    /// hooks.json 里是否已有我们的 Stop hook。
    public static func isInstalled() -> Bool {
        guard let data = try? Data(contentsOf: hooksFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else { return false }
        return hooksContainFlowCue(hooks)
    }

    /// Codex 只有在 config.toml 里留下 `[hooks.state."…:stop:…"]` 信任记录后才会执行 Stop hook。
    public static func isTrusted() -> Bool {
        let config = home.appendingPathComponent(".codex/config.toml")
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return false }
        for line in text.split(separator: "\n") where line.hasPrefix("[hooks.state.") {
            let key = line.lowercased()
            if key.contains(":stop:") || key.contains(":stop\"") { return true }
        }
        return false
    }

    private static func hooksContainFlowCue(_ hooks: [String: Any]) -> Bool {
        for (_, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            for group in groups {
                guard let commands = group["hooks"] as? [[String: Any]] else { continue }
                for command in commands {
                    if let text = command["command"] as? String, text.contains("flowcue-hook.sh") {
                        return true
                    }
                }
            }
        }
        return false
    }

    // MARK: 安装

    /// 写入脚本并把 Stop hook 合并进 hooks.json。已有同名 hook 时幂等。
    public static func install() throws {
        try FileManager.default.createDirectory(
            at: scriptFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try scriptContents.write(to: scriptFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptFile.path)
        if !FileManager.default.fileExists(atPath: eventsFile.path) {
            FileManager.default.createFile(atPath: eventsFile.path, contents: nil)
        }

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: hooksFile),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
            let backup = hooksFile.deletingPathExtension().appendingPathExtension("json.flowcue-backup")
            try? data.write(to: backup)
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var stops = hooks["Stop"] as? [[String: Any]] ?? []
        if !hooksContainFlowCue(["Stop": stops]) {
            stops.append([
                "hooks": [[
                    "type": "command",
                    "command": scriptFile.path,
                    "async": true,
                    "timeout": 5
                ]]
            ])
            hooks["Stop"] = stops
            root["hooks"] = hooks
            let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: hooksFile, options: .atomic)
        }
    }

    public static func uninstall() throws {
        guard let data = try? Data(contentsOf: hooksFile),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = root["hooks"] as? [String: Any],
              var stops = hooks["Stop"] as? [[String: Any]] else { return }
        stops.removeAll { group in
            guard let commands = group["hooks"] as? [[String: Any]] else { return false }
            return commands.contains { ($0["command"] as? String)?.contains("flowcue-hook.sh") == true }
        }
        if stops.isEmpty { hooks.removeValue(forKey: "Stop") } else { hooks["Stop"] = stops }
        root["hooks"] = hooks
        if let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            try out.write(to: hooksFile, options: .atomic)
        }
    }

    // MARK: 事件

    /// 读取最近的事件（最多 limit 条），忽略无法解析的行。
    public static func recentEvents(limit: Int = 50) -> [Event] {
        guard let text = try? String(contentsOf: eventsFile, encoding: .utf8) else { return [] }
        let decoder = ISO8601DateFormatter()
        var events: [Event] = []
        for line in text.split(separator: "\n").suffix(limit) {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let hookName = (json["hook_event_name"] as? String)
                ?? (json["event"] as? String)
                ?? "Stop"
            let sessionID = (json["session_id"] as? String)
                ?? (json["thread_id"] as? String)
                ?? (json["conversation_id"] as? String)
            let cwd = json["cwd"] as? String
            let stamp = (json["received_at"] as? String).flatMap { decoder.date(from: $0) } ?? Date()
            events.append(Event(type: hookName, sessionID: sessionID, cwd: cwd, receivedAt: stamp))
        }
        return events
    }

    private static let scriptContents = """
    #!/bin/sh
    # FlowCue agent hook（Codex / Claude 共用）
    # 用法：flowcue-hook.sh [codex|claude]
    # 把事件包成 {"source":..,"received_at":..,"payload":{..}} 追加到 spool 文件。
    mkdir -p "$HOME/.flowcue"
    source_name="${1:-codex}"
    payload=$(cat)
    stamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    printf '{"source":"%s","received_at":"%s","payload":%s}\\n' \
        "$source_name" "$stamp" "$payload" >> "$HOME/.flowcue/hook-events.jsonl"
    exit 0
    """
}
