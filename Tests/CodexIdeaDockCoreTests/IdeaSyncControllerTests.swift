import Foundation
import XCTest
@testable import CodexIdeaDockCore

@MainActor
final class IdeaSyncControllerTests: XCTestCase {
    func testUnconfiguredBuildCannotEnableCloudOrCreateOutbox() async throws {
        let suite = "Reroute.SyncControllerTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "Reroute.iCloudSyncEnabled")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.json")
        let store = try IdeaDockStore(modelContainer: IdeaDockPersistence.makeInMemoryContainer(), bridge: ControllerTestBridge(), userDefaults: defaults)
        store.draftText = "unsaved local draft"
        let controller = IdeaSyncController(store: store, defaults: defaults, containerIdentifier: nil, journalURL: url)
        controller.setEnabled(true)
        await controller.synchronizeNow()
        XCTAssertFalse(controller.isAvailable)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(store.draftText, "unsaved local draft")
    }

    func testConfiguredBuildStillRequiresOptIn() throws {
        let suite = "Reroute.SyncControllerTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = try IdeaDockStore(modelContainer: IdeaDockPersistence.makeInMemoryContainer(), bridge: ControllerTestBridge(), userDefaults: defaults)
        let controller = IdeaSyncController(store: store, defaults: defaults, containerIdentifier: "iCloud.synthetic.test")
        XCTAssertTrue(controller.isAvailable)
        XCTAssertFalse(controller.isEnabled)
        controller.setEnabled(true)
        XCTAssertTrue(defaults.bool(forKey: "Reroute.iCloudSyncEnabled"))
        controller.setEnabled(false)
        XCTAssertFalse(controller.isEnabled)
    }
}

private struct ControllerTestBridge: CodexBridging {
    func listThreads() async throws -> [WorkContextItem] { [] }
    func queue(message: String, to threadID: String) async -> QueueDeliveryOutcome { .failed(exitCode: nil, message: "unused") }
}
