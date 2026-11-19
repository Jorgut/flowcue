import CryptoKit
import Foundation

#if canImport(AppKit)
import AppKit
#endif

/// 把随 app 打包的 DSH 桥插件装进用户的 DSH profile。
///
/// 只装到**固定目录**：DSH profile 里注册的是一条 `link:`，指向会移动的路径
/// （app 升级、被拖到别处、工作区重排）时链接会断，桥接随之静默消失。
/// 所以这里先把插件复制到 `~/.flowcue/bridge/<version>`，再让 DSH 注册那个固定路径。
public enum DSHBridgeInstaller {

    public enum Status: Equatable, Sendable {
        /// 找不到 DeepSeek Harness：不该给「安装」按钮。
        case dshNotInstalled
        /// DSH 在，但桥没装。
        case bridgeMissing
        /// 已安装；`outdated` 表示包内插件比已装的新，需要更新后重启 DSH。
        case installed(version: String, outdated: Bool)
    }

    public struct Installation: Codable, Equatable, Sendable {
        public var version: String
        public var path: String
        public var digest: String

        public init(version: String, path: String, digest: String) {
            self.version = version
            self.path = path
            self.digest = digest
        }
    }

    public enum InstallError: LocalizedError, Equatable {
        case dshNotInstalled
        case bundledPluginMissing
        case invalidManifest
        case commandFailed(status: Int32, message: String)

        public var errorDescription: String? {
            switch self {
            case .dshNotInstalled:
                return "未检测到 DeepSeek Harness"
            case .bundledPluginMissing:
                return "这个 app 里没有带桥接插件"
            case .invalidManifest:
                return "桥接插件的 package.json 无法解析"
            case let .commandFailed(status, message):
                return "dsh plugin 执行失败（\(status)）：\(message)"
            }
        }
    }

    public static let pluginName = "flowcue-dsh-bridge"
    public static let dshBundleIdentifier = "com.deepseek.dsh"

    // MARK: 可注入的环境（测试用）

    nonisolated(unsafe) public static var home = URL(fileURLWithPath: NSHomeDirectory())
    nonisolated(unsafe) public static var dshApplicationOverride: URL?
    nonisolated(unsafe) public static var bundledPluginOverride: URL?

    // MARK: 路径

    /// `~/.flowcue/bridge`
    public static var rootDirectory: URL { home.appendingPathComponent(".flowcue/bridge") }
    /// `~/.flowcue/bridge-install.json`
    public static var recordFile: URL { home.appendingPathComponent(".flowcue/bridge-install.json") }
    /// `~/.dsh/profiles`
    public static var profilesDirectory: URL { home.appendingPathComponent(".dsh/profiles") }

    /// 随 app 打包的插件副本：`Contents/Resources/DSHBridge`。
    public static var bundledPluginDirectory: URL? {
        if let override = bundledPluginOverride { return override }
        guard let resources = Bundle.main.resourceURL else { return nil }
        return resources.appendingPathComponent("DSHBridge")
    }

    /// DeepSeek Harness.app 的位置。App 被拖到别处也能找到。
    public static var dshApplication: URL? {
        if let override = dshApplicationOverride { return override }
        #if canImport(AppKit)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: dshBundleIdentifier) {
            return url
        }
        #endif
        let fallback = URL(fileURLWithPath: "/Applications/DeepSeek Harness.app")
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    /// DSH 自带的 CLI。用户机器上不一定有 `dsh` 在 PATH 里，所以从 app 包里找。
    public static var dshCLI: URL? {
        guard let application = dshApplication else { return nil }
        let cli = application.appendingPathComponent("Contents/Resources/runtime/cli/bin/dsh")
        return FileManager.default.isExecutableFile(atPath: cli.path) ? cli : nil
    }

    /// 优先用 DSH 自己导出的 `DSH_PROFILE`，否则退回 `desktop` / 唯一的那个 profile。
    public static func profileName() -> String {
        if let name = ProcessInfo.processInfo.environment["DSH_PROFILE"], !name.isEmpty {
            return name
        }
        let desktop = profilesDirectory.appendingPathComponent("desktop")
        if FileManager.default.fileExists(atPath: desktop.path) { return "desktop" }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: profilesDirectory.path)) ?? []
        return names.sorted().first ?? "desktop"
    }

    // MARK: 状态

    public static func status() -> Status {
        guard dshCLI != nil else { return .dshNotInstalled }
        guard let record = loadRecord(),
              FileManager.default.fileExists(atPath: record.path) else { return .bridgeMissing }
        let outdated = bundledDigest().map { $0 != record.digest } ?? false
        return .installed(version: record.version, outdated: outdated)
    }

    // MARK: 安装 / 卸载

    /// 复制插件到固定目录并注册进 DSH profile。返回安装记录。
    /// 装完需要重启 DSH 才会加载。
    @discardableResult
    public static func install() throws -> Installation {
        guard let cli = dshCLI else { throw InstallError.dshNotInstalled }
        guard let bundled = bundledPluginDirectory,
              FileManager.default.fileExists(atPath: bundled.appendingPathComponent("index.js").path),
              let digest = digest(of: bundled) else {
            throw InstallError.bundledPluginMissing
        }

        let version = try pluginVersion(bundled)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

        // 先复制到临时目录再整体替换，避免中途失败留下半个插件。
        let staging = rootDirectory.appendingPathComponent(".staging-\(UUID().uuidString)")
        try? fileManager.removeItem(at: staging)
        try fileManager.copyItem(at: bundled, to: staging)
        let target = rootDirectory.appendingPathComponent(version)
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        try fileManager.moveItem(at: staging, to: target)

        let profile = profileName()
        // 先摘掉旧注册，避免升级后 profile 里留下指向旧目录的条目。
        _ = try? run(cli, arguments: ["plugin", "--profile", profile, "remove", pluginName])
        let result = try run(cli, arguments: ["plugin", "--profile", profile, "add", target.path])
        guard result.code == 0 else {
            throw InstallError.commandFailed(status: result.code, message: result.output)
        }

        let installation = Installation(version: version, path: target.path, digest: digest)
        try writeRecord(installation)
        return installation
    }

    public static func uninstall() throws {
        if let cli = dshCLI {
            _ = try? run(cli, arguments: ["plugin", "--profile", profileName(), "remove", pluginName])
        }
        if let record = loadRecord() {
            try? FileManager.default.removeItem(atPath: record.path)
        }
        try? FileManager.default.removeItem(at: rootDirectory)
        try? FileManager.default.removeItem(at: recordFile)
    }

    // MARK: 记录

    public static func loadRecord() -> Installation? {
        guard let data = try? Data(contentsOf: recordFile),
              let record = try? JSONDecoder().decode(Installation.self, from: data) else { return nil }
        return record
    }

    private static func writeRecord(_ installation: Installation) throws {
        let data = try JSONEncoder().encode(installation)
        try FileManager.default.createDirectory(
            at: recordFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: recordFile, options: .atomic)
    }

    // MARK: 内部

    private static func pluginVersion(_ directory: URL) throws -> String {
        let manifest = directory.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: manifest),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String,
              !version.isEmpty else {
            throw InstallError.invalidManifest
        }
        return version
    }

    private static func bundledDigest() -> String? {
        guard let bundled = bundledPluginDirectory else { return nil }
        return digest(of: bundled)
    }

    /// 对目录里所有普通文件按相对路径排序后做 SHA-256，用来判断包内插件是否变了。
    static func digest(of directory: URL) -> String? {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return nil }

        var files: [(path: String, data: Data)] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true,
                  let data = try? Data(contentsOf: url) else { continue }
            let prefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
            files.append((url.path.replacingOccurrences(of: prefix, with: ""), data))
        }
        guard !files.isEmpty else { return nil }

        var hasher = SHA256()
        for file in files.sorted(by: { $0.path < $1.path }) {
            hasher.update(data: Data(file.path.utf8))
            hasher.update(data: file.data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func run(_ executable: URL, arguments: [String]) throws -> (code: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = home

        var environment = ProcessInfo.processInfo.environment
        environment["DSH_PROFILE"] = profileName()
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // 先读干净再等退出，避免输出超过管道缓冲时互相卡住。
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
