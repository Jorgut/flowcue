import XCTest
@testable import CodexIdeaDockCore

final class DSHBridgeInstallerTests: XCTestCase {
    private var root: URL!
    private var fakeApp: URL!
    private var pluginSource: URL!
    private var cliLog: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowcue-bridge-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // 假 DSH.app：只放一个记录参数的 CLI，避免测试真的动用户的 profile。
        fakeApp = root.appendingPathComponent("DeepSeek Harness.app")
        let cli = fakeApp.appendingPathComponent("Contents/Resources/runtime/cli/bin/dsh")
        try FileManager.default.createDirectory(
            at: cli.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        cliLog = root.appendingPathComponent("cli-args.log")
        try """
        #!/bin/sh
        for argument in "$@"; do printf '%s\\n' "$argument"; done >> "\(cliLog.path)"
        printf '%s\\n' "---" >> "\(cliLog.path)"
        exit 0
        """.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)

        // 假「随包分发的插件」
        pluginSource = root.appendingPathComponent("DSHBridge")
        try FileManager.default.createDirectory(at: pluginSource, withIntermediateDirectories: true)
        try #"{"name":"flowcue-dsh-bridge","version":"0.1.0"}"#
            .write(to: pluginSource.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try "// bridge".write(
            to: pluginSource.appendingPathComponent("index.js"),
            atomically: true,
            encoding: .utf8
        )

        DSHBridgeInstaller.home = root
        DSHBridgeInstaller.dshApplicationOverride = fakeApp
        DSHBridgeInstaller.bundledPluginOverride = pluginSource
    }

    override func tearDownWithError() throws {
        DSHBridgeInstaller.home = URL(fileURLWithPath: NSHomeDirectory())
        DSHBridgeInstaller.dshApplicationOverride = nil
        DSHBridgeInstaller.bundledPluginOverride = nil
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: 状态

    func testStatusIsDSHNotInstalledWhenHarnessMissing() {
        DSHBridgeInstaller.dshApplicationOverride = root.appendingPathComponent("NoSuch.app")
        XCTAssertEqual(DSHBridgeInstaller.status(), .dshNotInstalled)
    }

    func testStatusIsBridgeMissingBeforeInstall() {
        XCTAssertEqual(DSHBridgeInstaller.status(), .bridgeMissing)
    }

    func testStatusIsInstalledAfterInstall() throws {
        try DSHBridgeInstaller.install()
        XCTAssertEqual(DSHBridgeInstaller.status(), .installed(version: "0.1.0", outdated: false))
    }

    // MARK: 安装

    func testInstallCopiesToFixedDirectoryAndRegistersProfile() throws {
        let installation = try DSHBridgeInstaller.install()

        let expected = root.appendingPathComponent(".flowcue/bridge/0.1.0")
        XCTAssertEqual(installation.version, "0.1.0")
        XCTAssertEqual(installation.path, expected.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.appendingPathComponent("index.js").path))
        XCTAssertEqual(DSHBridgeInstaller.loadRecord(), installation)

        // CLI 必须收到 add，且路径是复制后的固定目录，不是包内路径。
        let log = try String(contentsOf: cliLog, encoding: .utf8)
        XCTAssertTrue(log.contains("plugin"))
        XCTAssertTrue(log.contains("add"))
        XCTAssertTrue(log.contains(expected.path))
        XCTAssertFalse(log.contains(pluginSource.path))
    }

    func testInstallRemovesPreviousRegistrationBeforeAdding() throws {
        try DSHBridgeInstaller.install()
        let firstLog = try String(contentsOf: cliLog, encoding: .utf8)
        XCTAssertTrue(firstLog.contains("remove"))
        XCTAssertTrue(firstLog.contains(DSHBridgeInstaller.pluginName))
    }

    func testInstallIsIdempotent() throws {
        try DSHBridgeInstaller.install()
        try DSHBridgeInstaller.install()
        let directory = root.appendingPathComponent(".flowcue/bridge")
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(entries.sorted(), ["0.1.0"])
    }

    func testInstallFromBundledPathSurvivesSourceRemoval() throws {
        let installation = try DSHBridgeInstaller.install()
        // app 被删/被移动后，固定目录里的副本仍然完整。
        try FileManager.default.removeItem(at: pluginSource)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installation.path + "/index.js"))
    }

    // MARK: 更新

    func testStatusReportsOutdatedWhenBundleChanges() throws {
        try DSHBridgeInstaller.install()
        XCTAssertEqual(DSHBridgeInstaller.status(), .installed(version: "0.1.0", outdated: false))

        try "// bridge v2".write(
            to: pluginSource.appendingPathComponent("index.js"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(DSHBridgeInstaller.status(), .installed(version: "0.1.0", outdated: true))
    }

    // MARK: 失败

    func testInstallFailsWhenCLIExitsNonZero() throws {
        let cli = fakeApp.appendingPathComponent("Contents/Resources/runtime/cli/bin/dsh")
        try """
        #!/bin/sh
        printf '%s\\n' "boom" >&2
        exit 3
        """.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)

        XCTAssertThrowsError(try DSHBridgeInstaller.install()) { error in
            guard case DSHBridgeInstaller.InstallError.commandFailed(status: 3, _)? = error as? DSHBridgeInstaller.InstallError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        // 失败不能留下“已安装”的假记录。
        XCTAssertNil(DSHBridgeInstaller.loadRecord())
        XCTAssertEqual(DSHBridgeInstaller.status(), .bridgeMissing)
    }

    func testInstallThrowsWhenBundleHasNoPlugin() throws {
        try FileManager.default.removeItem(at: pluginSource)
        XCTAssertThrowsError(try DSHBridgeInstaller.install()) { error in
            XCTAssertEqual(error as? DSHBridgeInstaller.InstallError, .bundledPluginMissing)
        }
    }

    // MARK: 卸载

    func testUninstallClearsRecordAndDirectory() throws {
        try DSHBridgeInstaller.install()
        try DSHBridgeInstaller.uninstall()

        XCTAssertNil(DSHBridgeInstaller.loadRecord())
        XCTAssertFalse(FileManager.default.fileExists(atPath: DSHBridgeInstaller.rootDirectory.path))
        XCTAssertEqual(DSHBridgeInstaller.status(), .bridgeMissing)
    }

    // MARK: 摘要

    func testDigestIgnoresFileOrderButDetectsContent() throws {
        let first = DSHBridgeInstaller.digest(of: pluginSource)
        XCTAssertNotNil(first)
        XCTAssertEqual(first, DSHBridgeInstaller.digest(of: pluginSource))

        try "// changed".write(
            to: pluginSource.appendingPathComponent("index.js"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertNotEqual(first, DSHBridgeInstaller.digest(of: pluginSource))
    }
}
