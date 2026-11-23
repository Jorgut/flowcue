import XCTest
@testable import CodexIdeaDockCore

final class AgentDiscoveryTests: XCTestCase {
    func testScanFindsInstalledAgents() throws {
        let records = AgentDiscovery.scan()
        for r in records {
            print("• \(r.displayName)  [\(r.kind.rawValue)]  \(r.version ?? "-")  \(r.executablePath)  caps=\(r.capabilities.map(\.rawValue).sorted())")
        }
        // CI runner 上通常没有安装任何 agent；这里跳过而不是失败。
        try XCTSkipIf(records.isEmpty, "本机没有安装 Agent（CI 环境正常跳过）")
        // 检出的路径必须真实存在
        for r in records {
            XCTAssertTrue(FileManager.default.fileExists(atPath: r.executablePath))
        }
    }

    func testCatalogEntriesHaveUniqueIDs() {
        let ids = AgentDiscovery.catalog.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }
}
