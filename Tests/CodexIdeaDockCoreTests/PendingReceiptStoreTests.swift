import Foundation
import XCTest
@testable import CodexIdeaDockCore

/// Mac 在写 CloudKit 回执前退出时，下次启动要能把回执补写回去。
final class PendingReceiptStoreTests: XCTestCase {
    func testRoundTripsReceiptsAndClearsFileWhenEmpty() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("receipts.json")

        XCTAssertEqual(RemoteRelayClient.loadPendingReceipts(from: url), [:])

        let first = UUID(), second = UUID()
        let receipts = [first: Data([1, 2, 3]), second: Data([4, 5])]
        RemoteRelayClient.savePendingReceipts(receipts, to: url)
        XCTAssertEqual(RemoteRelayClient.loadPendingReceipts(from: url), receipts)

        RemoteRelayClient.savePendingReceipts([:], to: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(RemoteRelayClient.loadPendingReceipts(from: url), [:])
    }

    func testCorruptFileIsIgnored() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("receipts.json")
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(RemoteRelayClient.loadPendingReceipts(from: url), [:])
    }
}
