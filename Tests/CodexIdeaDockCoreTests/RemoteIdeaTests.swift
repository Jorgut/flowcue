import Foundation
import XCTest
@testable import CodexIdeaDockCore

private struct NoopBridge: CodexBridging {
    func listThreads() async throws -> [WorkContextItem] { [] }
    func queue(message: String, to threadID: String) async -> QueueDeliveryOutcome {
        .failed(exitCode: nil, message: "unused")
    }
}

@MainActor
final class RemoteIdeaTests: XCTestCase {
    private func makeStore() throws -> IdeaDockStore {
        try IdeaDockStore(
            modelContainer: IdeaDockPersistence.makeInMemoryContainer(),
            bridge: NoopBridge(),
            userDefaults: UserDefaults(suiteName: "RemoteIdeaTests-\(UUID().uuidString)")!
        )
    }

    func testUpsertIsIdempotentAndUpdatesText() throws {
        let store = try makeStore()
        let id = UUID()
        let createdAt = Date.now

        XCTAssertTrue(store.upsertRemoteIdea(
            RemoteIdea(id: id, text: "first", createdAt: createdAt, updatedAt: createdAt)
        ))
        XCTAssertEqual(store.captures.filter { $0.id == id }.count, 1)

        XCTAssertTrue(store.upsertRemoteIdea(
            RemoteIdea(id: id, text: "second", createdAt: createdAt, updatedAt: createdAt.addingTimeInterval(5))
        ))
        XCTAssertEqual(store.captures.filter { $0.id == id }.count, 1)
        XCTAssertEqual(store.captures.first { $0.id == id }?.text, "second")
    }

    func testEmptyRemoteIdeaIsRejected() throws {
        let store = try makeStore()
        XCTAssertFalse(store.upsertRemoteIdea(
            RemoteIdea(id: UUID(), text: "   ", createdAt: .now, updatedAt: .now)
        ))
        XCTAssertTrue(store.captures.isEmpty)
    }
}
