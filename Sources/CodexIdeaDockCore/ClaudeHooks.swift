import Foundation

/// 给 Claude Code 装 Stop hook：跑完一轮就把事件写到同一个 spool 文件。
/// 与 CodexHooks 共用脚本与文件，仅配置文件不同。
public enum ClaudeHooks {
    nonisolated(unsafe) public static var home: URL = URL(fileURLWithPath: NSHomeDirectory())
    public static var settingsFile: URL { home.appendingPathComponent(".claude/settings.json") }
    public static var scriptFile: URL { home.appendingPathComponent(".flowcue/flowcue-hook.sh") }

    public static func isInstalled() -> Bool {
        guard let data = try? Data(contentsOf: settingsFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any],
              let stops = hooks["Stop"] as? [[String: Any]] else { return false }
        return stops.contains { group in
            guard let commands = group["hooks"] as? [[String: Any]] else { return false }
            return commands.contains { ($0["command"] as? String)?.contains("flowcue-hook.sh") == true }
        }
    }

    public static func install() throws {
        try CodexHooks.install()  // 保证脚本存在且可执行

        var root: [String: Any] = [:]
        var existing: Data?
        if let data = try? Data(contentsOf: settingsFile),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
            existing = data
            let backup = settingsFile.deletingPathExtension().appendingPathExtension("json.flowcue-backup")
            try? data.write(to: backup)
        } else {
            try FileManager.default.createDirectory(
                at: settingsFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        _ = existing

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var stops = hooks["Stop"] as? [[String: Any]] ?? []
        let alreadyThere = stops.contains { group in
            guard let commands = group["hooks"] as? [[String: Any]] else { return false }
            return commands.contains { ($0["command"] as? String)?.contains("flowcue-hook.sh") == true }
        }
        if !alreadyThere {
            stops.append([
                "hooks": [[
                    "type": "command",
                    "command": "\(scriptFile.path) claude",
                    "async": true,
                    "timeout": 5
                ]]
            ])
            hooks["Stop"] = stops
            root["hooks"] = hooks
            let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: settingsFile, options: .atomic)
        }
    }

    public static func uninstall() throws {
        guard let data = try? Data(contentsOf: settingsFile),
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
            try out.write(to: settingsFile, options: .atomic)
        }
    }
}
