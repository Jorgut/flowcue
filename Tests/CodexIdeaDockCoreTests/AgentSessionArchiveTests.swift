import XCTest
@testable import CodexIdeaDockCore

final class AgentSessionArchiveTests: XCTestCase {
    private let suite = "flowcue.archive.tests"

    override func setUp() {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        AgentSessionArchive.defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        AgentSessionArchive.defaults = .standard
    }

    func testToggleStar() {
        XCTAssertFalse(AgentSessionArchive.isStarred(agentID: "codex", sessionID: "a"))
        XCTAssertTrue(AgentSessionArchive.toggle(agentID: "codex", sessionID: "a"))
        XCTAssertTrue(AgentSessionArchive.isStarred(agentID: "codex", sessionID: "a"))
        XCTAssertFalse(AgentSessionArchive.toggle(agentID: "codex", sessionID: "a"))
        XCTAssertFalse(AgentSessionArchive.isStarred(agentID: "codex", sessionID: "a"))
    }

    func testStarredIsScopedByAgent() {
        _ = AgentSessionArchive.toggle(agentID: "codex", sessionID: "a")
        XCTAssertTrue(AgentSessionArchive.isStarred(agentID: "codex", sessionID: "a"))
        XCTAssertFalse(AgentSessionArchive.isStarred(agentID: "claude", sessionID: "a"))
        XCTAssertEqual(AgentSessionArchive.starredIDs(agentID: "codex"), ["a"])
        XCTAssertTrue(AgentSessionArchive.starredIDs(agentID: "claude").isEmpty)
    }
}
