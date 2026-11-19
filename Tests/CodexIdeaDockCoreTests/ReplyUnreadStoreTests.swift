import Foundation
import XCTest
@testable import CodexIdeaDockCore

final class ReplyUnreadStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "ReplyUnreadStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testMarkUnreadIsPerSessionAndIdempotent() {
        let store = ReplyUnreadStore(defaults: makeDefaults())

        XCTAssertTrue(store.markUnread(agentID: "codex", sessionID: "a"))
        XCTAssertFalse(store.markUnread(agentID: "codex", sessionID: "a"), "同一会话不重复计数")
        XCTAssertTrue(store.markUnread(agentID: "claude", sessionID: "a"))

        XCTAssertEqual(store.count, 2)
        XCTAssertEqual(store.keys, ["codex:a", "claude:a"])
    }

    func testMarkReadRemovesOnlyThatSession() {
        let store = ReplyUnreadStore(defaults: makeDefaults())
        store.markUnread(agentID: "codex", sessionID: "a")
        store.markUnread(agentID: "codex", sessionID: "b")

        XCTAssertTrue(store.markRead(agentID: "codex", sessionID: "a"))
        XCTAssertFalse(store.markRead(agentID: "codex", sessionID: "a"), "已读再读不算变化")
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.keys, ["codex:b"])
    }

    func testPersistenceAcrossInstances() {
        let defaults = makeDefaults()
        let first = ReplyUnreadStore(defaults: defaults)
        first.markUnread(agentID: "dsh", sessionID: "z")

        let second = ReplyUnreadStore(defaults: defaults)
        XCTAssertEqual(second.count, 1)
        XCTAssertTrue(second.keys.contains("dsh:z"))
    }

    func testClearAllEmptiesAndNotifies() {
        let store = ReplyUnreadStore(defaults: makeDefaults())
        var changes = 0
        store.onChange = { changes += 1 }
        store.markUnread(agentID: "codex", sessionID: "a")

        XCTAssertTrue(store.clearAll())
        XCTAssertEqual(store.count, 0)
        XCTAssertFalse(store.clearAll(), "空集合不触发第二次变更")
        XCTAssertEqual(changes, 2, "标记一次 + 清空一次")
    }
}
