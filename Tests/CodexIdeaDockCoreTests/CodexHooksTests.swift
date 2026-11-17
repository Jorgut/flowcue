import XCTest
@testable import CodexIdeaDockCore

final class CodexHooksTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("flowcue-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        CodexHooks.home = root
    }

    override func tearDownWithError() throws {
        CodexHooks.home = URL(fileURLWithPath: NSHomeDirectory())
        try? FileManager.default.removeItem(at: root)
    }

    func testInstallMergesAndIsIdempotent() throws {
        let existing = """
        { "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "echo other" } ] } ] } }
        """
        try existing.write(to: CodexHooks.hooksFile, atomically: true, encoding: .utf8)

        XCTAssertFalse(CodexHooks.isInstalled())
        try CodexHooks.install()
        XCTAssertTrue(CodexHooks.isInstalled())
        XCTAssertTrue(FileManager.default.fileExists(atPath: CodexHooks.scriptFile.path))

        // 原有 hook 仍在
        let data = try Data(contentsOf: CodexHooks.hooksFile)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("echo other"))
        XCTAssertTrue(text.contains("flowcue-hook.sh"))

        // 再装一次不重复
        try CodexHooks.install()
        let count = text.components(separatedBy: "flowcue-hook.sh").count - 1
        let again = String(decoding: try Data(contentsOf: CodexHooks.hooksFile), as: UTF8.self)
            .components(separatedBy: "flowcue-hook.sh").count - 1
        XCTAssertEqual(count, again)
    }

    func testUninstallRemovesOnlyOurHook() throws {
        try """
        { "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "echo other" } ] } ] } }
        """.write(to: CodexHooks.hooksFile, atomically: true, encoding: .utf8)
        try CodexHooks.install()
        try CodexHooks.uninstall()
        XCTAssertFalse(CodexHooks.isInstalled())
        let text = String(decoding: try Data(contentsOf: CodexHooks.hooksFile), as: UTF8.self)
        XCTAssertTrue(text.contains("echo other"))
    }

    func testRecentEventsParsesLines() throws {
        try FileManager.default.createDirectory(at: CodexHooks.eventsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = """
        {"hook_event_name":"Stop","session_id":"abc","cwd":"/tmp","received_at":"2026-11-17T09:00:00Z"}
        not-json
        {"session_id":"def"}
        """
        try lines.write(to: CodexHooks.eventsFile, atomically: true, encoding: .utf8)
        let events = CodexHooks.recentEvents()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first?.sessionID, "abc")
        XCTAssertEqual(events.last?.type, "Stop")
    }
}
