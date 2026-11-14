import XCTest
@testable import CodexIdeaDockCore

final class AgentDiscoveryTests: XCTestCase {
    func testScanFindsInstalledAgents() throws {
        let records = AgentDiscovery.scan()
        for r in records {
            print("• \(r.displayName)  [\(r.kind.rawValue)]  \(r.version ?? "-")  \(r.executablePath)  caps=\(r.capabilities.map(\.rawValue).sorted())")
        }
        // 本机至少装了一个 agent；否则说明目录表漏了路径
        XCTAssertFalse(records.isEmpty, "扫描结果为空，检查 AgentDiscovery.catalog 的候选路径")
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
