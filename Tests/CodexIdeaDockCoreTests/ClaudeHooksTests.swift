import XCTest
@testable import CodexIdeaDockCore

final class ClaudeHooksTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("flowcue-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        ClaudeHooks.home = root
        CodexHooks.home = root
    }

    override func tearDownWithError() throws {
        ClaudeHooks.home = URL(fileURLWithPath: NSHomeDirectory())
        CodexHooks.home = URL(fileURLWithPath: NSHomeDirectory())
        try? FileManager.default.removeItem(at: root)
    }

    func testInstallAddsStopHookAndKeepsOthers() throws {
        try """
        { "env": { "FOO": "bar" }, "hooks": { "Notification": [ { "hooks": [ { "type": "command", "command": "echo notify" } ] } ] } }
        """.write(to: ClaudeHooks.settingsFile, atomically: true, encoding: .utf8)

        XCTAssertFalse(ClaudeHooks.isInstalled())
        try ClaudeHooks.install()
        XCTAssertTrue(ClaudeHooks.isInstalled())

        let text = String(decoding: try Data(contentsOf: ClaudeHooks.settingsFile), as: UTF8.self)
        XCTAssertTrue(text.contains("echo notify"), "原有 hooks 必须保留")
        XCTAssertTrue(text.contains("flowcue-hook.sh claude"))
        XCTAssertTrue(text.contains("\"FOO\""), "env 等其它配置必须保留")

        try ClaudeHooks.install()
        let count = String(decoding: try Data(contentsOf: ClaudeHooks.settingsFile), as: UTF8.self)
            .components(separatedBy: "flowcue-hook.sh").count - 1
        XCTAssertEqual(count, 1, "重复安装不应产生多条")
    }

    func testUninstallKeepsOtherHooks() throws {
        try """
        { "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "echo stop" } ] } ] } }
        """.write(to: ClaudeHooks.settingsFile, atomically: true, encoding: .utf8)
        try ClaudeHooks.install()
        try ClaudeHooks.uninstall()
        XCTAssertFalse(ClaudeHooks.isInstalled())
        let text = String(decoding: try Data(contentsOf: ClaudeHooks.settingsFile), as: UTF8.self)
        XCTAssertTrue(text.contains("echo stop"))
    }
}
