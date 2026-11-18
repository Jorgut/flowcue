import Foundation
import XCTest
@testable import CodexIdeaDockCore

final class SharedIdeaSyncTests: XCTestCase {
    private func note(_ text: String, id: UUID = UUID()) -> SharedIdea {
        SharedIdea(id: id, text: text, createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2), archived: false)
    }

    func testConcurrentEditsPreserveBothVersionsAndConverge() throws {
        let initial = note("original")
        var first = IdeaSyncJournal()
        try first.stageLocalChanges([initial])
        first.acknowledgeApplied([initial])
        var second = IdeaSyncJournal()
        try second.merge(first.revisions)
        second.acknowledgeApplied([initial])
        var phone = initial
        phone.text = "phone edit"
        var mac = initial
        mac.text = "Mac edit"
        try first.stageLocalChanges([phone])
        try second.stageLocalChanges([mac])
        let firstRevisions = first.revisions
        try first.merge(second.revisions)
        try second.merge(firstRevisions)
        XCTAssertEqual(first.projection, second.projection)
        XCTAssertEqual(Set(first.projection.map(\.text)), ["phone edit", "Mac edit"])
        XCTAssertEqual(Set(first.projection.map(\.id)).count, 2)
    }

    func testRetryDoesNotCreateAnotherRevision() throws {
        var journal = IdeaSyncJournal()
        let idea = note("offline idea")
        try journal.stageLocalChanges([idea])
        try journal.stageLocalChanges([idea])
        XCTAssertEqual(journal.revisions.count, 1)
        let first = journal.revisions
        try journal.merge(first)
        XCTAssertEqual(journal.revisions, first)
    }

    func testJournalCannotBeReusedForAnotherCloudAccount() throws {
        var journal = IdeaSyncJournal()
        try journal.bindAccount("test-account-A")
        try journal.bindAccount("test-account-A")
        XCTAssertThrowsError(try journal.bindAccount("test-account-B"))
        XCTAssertEqual(journal.accountID, "test-account-A")
    }

    func testMalformedMergeIsAtomic() throws {
        var journal = IdeaSyncJournal()
        try journal.stageLocalChanges([note("kept")])
        let before = journal.revisions
        let id = UUID()
        let invalid = IdeaRevision(id: id, deviceID: UUID(), parents: [id], idea: note("invalid"))
        XCTAssertThrowsError(try journal.merge([invalid]))
        XCTAssertEqual(journal.revisions, before)
    }

    func testSameRevisionIDCannotReplaceContent() throws {
        var journal = IdeaSyncJournal()
        try journal.stageLocalChanges([note("original")])
        let original = try XCTUnwrap(journal.revisions.first)
        var replacement = original.idea
        replacement.text = "replacement"
        XCTAssertThrowsError(try journal.merge([IdeaRevision(id: original.id, deviceID: original.deviceID, parents: [], idea: replacement)]))
        XCTAssertEqual(journal.projection.first?.text, "original")
    }

    @MainActor
    func testImportDoesNotSendAndInvalidBatchRollsBack() async throws {
        let suite = "Reroute.SyncTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let bridge = SyncImportBridge()
        let store = try IdeaDockStore(modelContainer: IdeaDockPersistence.makeInMemoryContainer(), bridge: bridge, userDefaults: defaults)
        let original = note("phone idea")
        try store.applySharedIdeas([original])
        XCTAssertEqual(store.sharedIdeas, [original])
        var changed = original
        changed.text = "changed"
        XCTAssertThrowsError(try store.applySharedIdeas([changed, note(" ")]))
        XCTAssertEqual(store.sharedIdeas, [original])
        let calls = await bridge.calls
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testFailedNetworkKeepsDurableOutbox() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sync.json")
        let transport = FakeRevisionTransport()
        transport.failFetch = true
        let session = try IdeaSyncSession(journalURL: url, transport: transport)
        let local = note("waiting offline")
        do {
            try await session.synchronize(readLocal: { [local] }, apply: { _ in XCTFail("Must not import after failed fetch") })
            XCTFail("Expected offline failure")
        } catch {}
        let restarted = try IdeaSyncSession(journalURL: url, transport: transport)
        XCTAssertEqual(restarted.journal.projection, [local])
        transport.failFetch = false
        try await restarted.synchronize(readLocal: { [local] }, apply: { XCTAssertEqual($0, [local]) })
        XCTAssertEqual(transport.uploaded.count, 1)
        try await restarted.synchronize(readLocal: { [local] }, apply: { _ in })
        XCTAssertEqual(transport.uploaded.count, 1)
    }
}

@MainActor
private final class FakeRevisionTransport: IdeaRevisionTransport {
    var failFetch = false
    var uploaded: [IdeaRevision] = []
    func accountIdentifier() async throws -> String { "synthetic-account" }
    func fetchRevisions() async throws -> [IdeaRevision] {
        if failFetch { throw URLError(.notConnectedToInternet) }
        return uploaded
    }
    func upload(_ revisions: [IdeaRevision]) async throws { uploaded.append(contentsOf: revisions) }
}

private actor SyncImportBridge: CodexBridging {
    var calls = 0
    func listThreads() async throws -> [WorkContextItem] { [] }
    func queue(message: String, to threadID: String) async -> QueueDeliveryOutcome {
        calls += 1
        return .queued(exitCode: 0)
    }
}
