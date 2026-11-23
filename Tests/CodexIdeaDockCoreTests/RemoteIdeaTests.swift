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

    // MARK: - 墓碑（删除双向同步）

    func testDeleteWritesTombstoneInsteadOfHardRemoval() throws {
        let store = try makeStore()
        let now = Date()
        let idea = RemoteIdea(id: UUID(), text: "要删的", createdAt: now, updatedAt: now)
        XCTAssertTrue(store.upsertRemoteIdea(idea))
        XCTAssertEqual(store.captures.count, 1)

        XCTAssertTrue(store.delete(idea.id))
        // 列表里看不到
        XCTAssertTrue(store.captures.isEmpty)
        // 但同步快照里还在，并且带墓碑时间——否则对端永远收不到删除
        let snapshot = store.syncSnapshot()
        let tombstone = try XCTUnwrap(snapshot.first { $0.id == idea.id })
        XCTAssertNotNil(tombstone.deletedAt)
    }

    func testRemoteTombstoneDeletesLocally() throws {
        let store = try makeStore()
        let now = Date()
        let idea = RemoteIdea(id: UUID(), text: "另一端删掉的", createdAt: now, updatedAt: now)
        XCTAssertTrue(store.upsertRemoteIdea(idea))
        XCTAssertEqual(store.captures.count, 1)

        let deletion = RemoteIdea(
            id: idea.id,
            text: idea.text,
            createdAt: idea.createdAt,
            updatedAt: now.addingTimeInterval(10),
            deletedAt: now.addingTimeInterval(10)
        )
        XCTAssertEqual(store.mergePulledIdeas([deletion]), 1)
        XCTAssertTrue(store.captures.isEmpty)
    }

    func testOlderRemoteTombstoneDoesNotDeleteNewerLocalEdit() throws {
        let store = try makeStore()
        let now = Date()
        let idea = RemoteIdea(id: UUID(), text: "本地新改的", createdAt: now, updatedAt: now.addingTimeInterval(60))
        XCTAssertTrue(store.upsertRemoteIdea(idea))

        let staleDeletion = RemoteIdea(
            id: idea.id,
            text: "旧正文",
            createdAt: now,
            updatedAt: now,
            deletedAt: now
        )
        XCTAssertEqual(store.mergePulledIdeas([staleDeletion]), 0)
        XCTAssertEqual(store.captures.count, 1)
        XCTAssertEqual(store.captures.first?.text, "本地新改的")
    }

    func testArchivedStatusTravelsThroughSync() throws {
        let store = try makeStore()
        let now = Date()
        let idea = RemoteIdea(id: UUID(), text: "归档同步", createdAt: now, updatedAt: now)
        XCTAssertTrue(store.upsertRemoteIdea(idea))

        let archived = RemoteIdea(
            id: idea.id,
            text: idea.text,
            createdAt: idea.createdAt,
            updatedAt: now.addingTimeInterval(5),
            status: CaptureStatus.archived.rawValue
        )
        XCTAssertEqual(store.mergePulledIdeas([archived]), 1)
        XCTAssertEqual(store.captures.first?.status, .archived)

        // 归档状态也要出现在快照里，才能传给对端
        let snapshot = store.syncSnapshot()
        XCTAssertEqual(snapshot.first?.status, CaptureStatus.archived.rawValue)
    }

    func testRemoteDraftIsStoredAsSavedSoItAppearsInTheList() throws {
        let store = try makeStore()
        let now = Date()
        // 手机新建的想法状态是 draft；直接照搬会让它在 Mac 列表里消失。
        let idea = RemoteIdea(
            id: UUID(),
            text: "手机新建的想法",
            createdAt: now,
            updatedAt: now,
            status: CaptureStatus.draft.rawValue
        )
        XCTAssertTrue(store.upsertRemoteIdea(idea))
        XCTAssertEqual(store.captures.count, 1)
        XCTAssertEqual(store.captures.first?.status, .saved)
        // 列表能看见（filteredCaptures 不显示草稿）
        XCTAssertEqual(store.filteredCaptures.count, 1)
    }

    func testExistingDraftIsPromotedWhenRemoteHasContent() throws {
        let store = try makeStore()
        let now = Date()
        let id = UUID()
        XCTAssertTrue(store.upsertRemoteIdea(RemoteIdea(
            id: id, text: "先是草稿", createdAt: now, updatedAt: now,
            status: CaptureStatus.draft.rawValue
        )))
        // 再推一次带内容的更新
        XCTAssertEqual(store.mergePulledIdeas([RemoteIdea(
            id: id, text: "草稿补全了", createdAt: now, updatedAt: now.addingTimeInterval(5),
            status: CaptureStatus.draft.rawValue
        )]), 1)
        XCTAssertEqual(store.captures.first?.status, .saved)
    }

    // MARK: - 同步边界

    func testQueuedIdeaIsNotOverwrittenByRemote() throws {
        let store = try makeStore()
        let now = Date()
        let id = UUID()
        XCTAssertTrue(store.upsertRemoteIdea(RemoteIdea(
            id: id, text: "要排队发送的", createdAt: now, updatedAt: now
        )))
        // 直接把状态置为排队中（等价于本机队列的状态）
        store.setStatusForTesting(captureID: id, status: .queued)
        XCTAssertEqual(store.captures.first?.status, .queued)

        // 另一台设备（更晚的时间）推来不同正文
        XCTAssertEqual(store.mergePulledIdeas([RemoteIdea(
            id: id, text: "远端改过的正文", createdAt: now, updatedAt: now.addingTimeInterval(60)
        )]), 0)
        XCTAssertEqual(store.captures.first?.text, "要排队发送的", "排队中的正文被覆盖了")
        XCTAssertEqual(store.captures.first?.status, .queued)
    }

    func testNewerRemoteTextWins() throws {
        let store = try makeStore()
        let now = Date()
        let id = UUID()
        XCTAssertTrue(store.upsertRemoteIdea(RemoteIdea(
            id: id, text: "旧正文", createdAt: now, updatedAt: now
        )))
        XCTAssertEqual(store.mergePulledIdeas([RemoteIdea(
            id: id, text: "新正文", createdAt: now, updatedAt: now.addingTimeInterval(30)
        )]), 1)
        XCTAssertEqual(store.captures.first?.text, "新正文")
    }

    func testOlderRemoteTextIsIgnored() throws {
        let store = try makeStore()
        let now = Date()
        let id = UUID()
        XCTAssertTrue(store.upsertRemoteIdea(RemoteIdea(
            id: id, text: "本地最新", createdAt: now, updatedAt: now.addingTimeInterval(60)
        )))
        XCTAssertEqual(store.mergePulledIdeas([RemoteIdea(
            id: id, text: "远端旧文", createdAt: now, updatedAt: now
        )]), 0)
        XCTAssertEqual(store.captures.first?.text, "本地最新")
    }

    func testRestoreFromTrashSyncsBack() throws {
        let store = try makeStore()
        let now = Date()
        let id = UUID()
        XCTAssertTrue(store.upsertRemoteIdea(RemoteIdea(
            id: id, text: "删了又恢复", createdAt: now, updatedAt: now
        )))
        XCTAssertTrue(store.delete(id))
        XCTAssertTrue(store.captures.isEmpty)
        XCTAssertTrue(store.restore(id))
        XCTAssertEqual(store.captures.count, 1)
        // 快照里不能再有墓碑，否则对端会继续把它当删除
        let snapshot = store.syncSnapshot().first { $0.id == id }
        XCTAssertNil(snapshot?.deletedAt)
    }
}
