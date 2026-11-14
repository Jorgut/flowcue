import Foundation

/// 本机 agent 的发现结果。只描述“有什么”，不做驱动。
public struct AgentRecord: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case cli      // 命令行工具，可被调用
        case app      // 桌面应用，仅检测
    }

    public enum Capability: String, Sendable {
        case detect     // 只能列出
        case session    // 能列会话
        case chat       // 能读对话
        case drive      // 能发消息
    }

    public let id: String
    public let displayName: String
    public let kind: Kind
    public let executablePath: String
    public let version: String?
    public let configDirectory: String?
    public let capabilities: Set<Capability>

    public var isInstalled: Bool { true }
}

public enum AgentDiscovery {
    /// 内置目录：候选路径 + 配置目录 + 能力。
    /// 路径按优先级排列，命中第一个即可。
    public struct Entry: Sendable {
        public let id: String
        public let displayName: String
        public let kind: AgentRecord.Kind
        public let candidates: [String]
        public let configDirectories: [String]
        public let capabilities: Set<AgentRecord.Capability>
    }

    private static func home(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    public static let catalog: [Entry] = [
        Entry(id: "codex", displayName: "Codex", kind: .cli,
              candidates: ["/opt/homebrew/bin/codex", "~/.local/bin/codex", "/usr/local/bin/codex"],
              configDirectories: ["~/.codex"],
              capabilities: [.detect, .session, .chat, .drive]),
        Entry(id: "claude", displayName: "Claude Code", kind: .cli,
              candidates: ["~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"],
              configDirectories: ["~/.claude"],
              capabilities: [.detect, .session, .chat, .drive]),
        Entry(id: "dsh", displayName: "DSH", kind: .cli,
              candidates: [],
              configDirectories: ["~/.flowcue"],
              capabilities: [.detect, .session, .chat, .drive]),
        Entry(id: "opencode", displayName: "OpenCode", kind: .cli,
              candidates: ["/opt/homebrew/bin/opencode", "~/.local/bin/opencode"],
              configDirectories: ["~/.config/opencode"],
              capabilities: [.detect]),
        Entry(id: "hermes", displayName: "Hermes", kind: .cli,
              candidates: ["~/.local/bin/hermes", "/opt/homebrew/bin/hermes"],
              configDirectories: ["~/.hermes"],
              capabilities: [.detect]),
        Entry(id: "pi", displayName: "Pi", kind: .cli,
              candidates: ["/opt/homebrew/bin/pi", "~/.local/bin/pi"],
              configDirectories: ["~/.pi"],
              capabilities: [.detect]),
        Entry(id: "grok", displayName: "Grok", kind: .cli,
              candidates: ["~/.grok/bin/grok", "/opt/homebrew/bin/grok"],
              configDirectories: ["~/.grok"],
              capabilities: [.detect]),
        Entry(id: "antigravity", displayName: "Antigravity", kind: .cli,
              candidates: ["~/.local/bin/agy", "/opt/homebrew/bin/agy"],
              configDirectories: [],
              capabilities: [.detect]),
        Entry(id: "claude-app", displayName: "Claude Desktop", kind: .app,
              candidates: ["/Applications/Claude.app"],
              configDirectories: ["~/Library/Application Support/Claude"],
              capabilities: [.detect]),
        Entry(id: "opencode-app", displayName: "OpenCode 桌面端", kind: .app,
              candidates: ["/Applications/OpenCode.app"],
              configDirectories: [],
              capabilities: [.detect]),
        Entry(id: "cursor", displayName: "Cursor", kind: .app,
              candidates: ["/Applications/Cursor.app"],
              configDirectories: ["~/.cursor"],
              capabilities: [.detect])
    ]

    /// 扫描本机。只读：不安装、不启动、不改配置。
    public static func scan(versionTimeout: TimeInterval = 1.5) -> [AgentRecord] {
        catalog.compactMap { entry in
            // 无 CLI 候选的（如 DSH）用配置目录判定“已接入”
            var path = entry.candidates.map(home).first { FileManager.default.fileExists(atPath: $0) }
            if path == nil, entry.candidates.isEmpty {
                path = entry.configDirectories.map(home).first { FileManager.default.fileExists(atPath: $0) }
            }
            guard let path else { return nil }
            let version = entry.kind == .cli ? readVersion(at: path, timeout: versionTimeout) : nil
            let config = entry.configDirectories.map(home).first { FileManager.default.fileExists(atPath: $0) }
            return AgentRecord(id: entry.id,
                               displayName: entry.displayName,
                               kind: entry.kind,
                               executablePath: path,
                               version: version,
                               configDirectory: config,
                               capabilities: entry.capabilities)
        }
        .sorted { $0.kind.rawValue == $1.kind.rawValue ? $0.displayName < $1.displayName : $0.kind == .cli }
    }

    /// 跑 `<binary> --version`，取第一行前 60 字。
    private static func readVersion(at path: String, timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning { process.terminate() }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8)?
            .split(separator: "\n").first else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(60))
    }
}
