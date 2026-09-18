import Foundation
import SwiftData
import XCTest
@testable import CodexIdeaDockCore

private actor BridgeState {
    var contexts: [WorkContextItem]
    var outcomes: [QueueDeliveryOutcome]
    var queued: [(String, String)] = []

    init(
        contexts: [WorkContextItem] = [],
        outcomes: [QueueDeliveryOutcome] = []
    ) {
        self.contexts = contexts
        self.outcomes = outcomes
    }

    func record(message: String, threadID: String) -> QueueDeliveryOutcome {
        queued.append((message, threadID))
        return outcomes.isEmpty ? .queued(exitCode: 0) : outcomes.removeFirst()
    }
}

private struct TestBridge: CodexBridging, Sendable {
    let state: BridgeState

    func listThreads() async throws -> [WorkContextItem] {
        await state.contexts
    }

    func queue(message: String, to threadID: String) async -> QueueDeliveryOutcome {
        await state.record(message: message, threadID: threadID)
    }
}

private actor RecoveringListBridge: CodexBridging {
    private let contexts: [WorkContextItem]
    private var listAttemptCount = 0

    init(contexts: [WorkContextItem]) {
        self.contexts = contexts
    }

    func listThreads() async throws -> [WorkContextItem] {
        listAttemptCount += 1
        if listAttemptCount == 1 {
            throw RecoveringListBridgeError.initialFailure
        }
        return contexts
    }

    func queue(message: String, to threadID: String) async -> QueueDeliveryOutcome {
        .failed(exitCode: nil, message: "Queue is not used by this test bridge.")
    }
}

private enum RecoveringListBridgeError: Error {
    case initialFailure
}

private actor QueueGate: CodexBridging {
    struct Call: Sendable {
        let message: String
        let threadID: String
    }

    let contexts: [WorkContextItem]
    let outcome: QueueDeliveryOutcome
    private(set) var calls: [Call] = []
    private var hasReleased = false

    init(
        contexts: [WorkContextItem],
        outcome: QueueDeliveryOutcome
    ) {
        self.contexts = contexts
        self.outcome = outcome
    }

    func listThreads() async throws -> [WorkContextItem] {
        contexts
    }

    func queue(message: String, to threadID: String) async -> QueueDeliveryOutcome {
        calls.append(Call(message: message, threadID: threadID))

        while !hasReleased {
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                return outcome
            }
        }
        return outcome
    }

    func waitUntilCalled(timeout: Duration = .seconds(2)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while calls.isEmpty, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return !calls.isEmpty
    }

    func release() {
        hasReleased = true
    }

    func recordedCalls() -> [Call] {
        calls
    }
}

private actor AsyncCompletion {
    private var isFinished = false

    func finish() {
        isFinished = true
    }

    func wait(timeout: Duration = .seconds(2)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !isFinished, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return isFinished
    }
}

@MainActor
final class IdeaDockStoreTests: XCTestCase {
    nonisolated(unsafe) private var defaults: UserDefaults!
    nonisolated(unsafe) private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "CodexIdeaDockTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    private func makeDefaults() -> UserDefaults {
        defaults
    }

    private func makeContainer() throws -> ModelContainer {
        try IdeaDockPersistence.makeInMemoryContainer()
    }

    private func makeContext(
        id: String,
        title: String,
        pinned: Bool = false,
        recency: Date = .now
    ) -> WorkContextItem {
        WorkContextItem(
            id: id,
            title: title,
            projectDirectory: "/tmp/\(id)",
            projectID: "project-\(id)",
            isPinned: pinned,
            recency: recency
        )
    }

    private func seed(
        captures: [Capture] = [],
        contexts: [WorkContext] = [],
        in container: ModelContainer
    ) throws {
        let modelContext = ModelContext(container)
        contexts.forEach(modelContext.insert)
        captures.forEach(modelContext.insert)
        try modelContext.save()
    }

    func testDraftAutomaticallyRecoversAcrossStoreInstances() throws {
        let context = makeContext(id: "source", title: "节目任务", pinned: true)
        let bridge = TestBridge(state: BridgeState(contexts: [context]))
        let container = try makeContainer()
        let first = try IdeaDockStore(
            modelContainer: container,
            bridge: bridge,
            userDefaults: makeDefaults()
        )

        first.setSource("source")
        first.setTarget("source")
        first.draftText = "保留这段想法\n包括中文输入法内容"

        let second = try IdeaDockStore(
            modelContainer: container,
            bridge: bridge,
            userDefaults: makeDefaults()
        )

        XCTAssertEqual(second.draftText, "保留这段想法\n包括中文输入法内容")
        XCTAssertEqual(second.sourceThreadID, "source")
        XCTAssertEqual(second.targetThreadID, "source")
    }

    func testUnknownPersistedStatusRawValueFailsClosedAsUnknown() throws {
        let container = try makeContainer()
        let capture = Capture(text: "来自未来版本的状态", status: .saved)
        capture.statusRawValue = "future-delivery-status"
        try seed(captures: [capture], in: container)

        let store = try IdeaDockStore(
            modelContainer: container,
            bridge: TestBridge(state: BridgeState()),
            userDefaults: makeDefaults()
        )

        XCTAssertEqual(store.captures.first { $0.id == capture.id }?.status, .unknown)
    }

    func testSourceAndTargetArePersistedIndependently() async throws {
        let source = makeContext(id: "show", title: "当前节目")
        let target = makeContext(id: "skill", title: "Podcast Skill", pinned: true)
        let bridge = TestBridge(state: BridgeState(contexts: [source, target]))
        let store = try IdeaDockStore(
            modelContainer: makeContainer(),
            bridge: bridge,
            userDefaults: makeDefaults()
        )

        await store.bootstrap()
        store.setSource("show")
        store.setTarget("skill")
        store.draftText = "节目制作中发现 Skill 应改进"
        let captureID: UUID = try XCTUnwrap(store.saveCurrent())
        let capture: CaptureItem = try XCTUnwrap(store.captures.first { $0.id == captureID })

        XCTAssertEqual(capture.sourceThreadID, "show")
        XCTAssertEqual(capture.targetThreadID, "skill")
        XCTAssertEqual(capture.sourceTitle, "当前节目")
        XCTAssertEqual(capture.targetTitle, "Podcast Skill")
    }

    func testSuccessfulQueueKeepsLocalCopyAndClearsDraft() async throws {
        let context = makeContext(id: "target", title: "目标任务")
        let state = BridgeState(
            contexts: [context],
            outcomes: [.queued(exitCode: 0)]
        )
        let bridge = TestBridge(state: state)
        let store = try IdeaDockStore(
            modelContainer: makeContainer(),
            bridge: bridge,
            userDefaults: makeDefaults()
        )

        await store.bootstrap()
        store.setTarget("target")
        store.draftText = "显式排队，不打断当前执行"
        await store.queueCurrent()

        let queuedCapture: CaptureItem = try XCTUnwrap(
            store.captures.first { $0.text == "显式排队，不打断当前执行" }
        )
        let queuedMessages = await state.queued
        XCTAssertEqual(queuedCapture.status, .queued)
        XCTAssertEqual(store.draftText, "")
        XCTAssertEqual(queuedMessages.map(\.0), ["显式排队，不打断当前执行"])
        XCTAssertEqual(queuedMessages.map(\.1), ["target"])
    }

    func testFailedQueueRetainsOriginalTextAndError() async throws {
        let context = makeContext(id: "target", title: "目标任务")
        let bridge = TestBridge(state: BridgeState(
            contexts: [context],
            outcomes: [.failed(exitCode: 9, message: "Codex CLI is unavailable.")]
        ))
        let store = try IdeaDockStore(
            modelContainer: makeContainer(),
            bridge: bridge,
            userDefaults: makeDefaults()
        )

        await store.bootstrap()
        store.setTarget("target")
        store.draftText = "失败也不能丢失"
        await store.queueCurrent()

        let capture: CaptureItem = try XCTUnwrap(store.captures.first { $0.text == "失败也不能丢失" })
        XCTAssertEqual(capture.status, .failed)
        XCTAssertEqual(capture.lastError, "Codex CLI is unavailable.")
        XCTAssertEqual(store.draftText, "失败也不能丢失")
    }

    func testFailedActiveDraftCountsOnlyOnce() async throws {
        let target = makeContext(id: "target", title: "目标任务")
        let state = BridgeState(
            contexts: [target],
            outcomes: [.failed(exitCode: 2, message: "Codex could not queue the message.")]
        )
        let store = try IdeaDockStore(
            modelContainer: makeContainer(),
            bridge: TestBridge(state: state),
            userDefaults: makeDefaults()
        )

        await store.bootstrap()
        store.setTarget(target.id)
        store.draftText = "失败后仍保留"
        await store.queueCurrent()

        XCTAssertEqual(store.pendingCount, 1)
        XCTAssertEqual(store.captures.first?.status, .failed)
        XCTAssertEqual(store.draftText, "失败后仍保留")
    }

    func testQueuePersistsOnlyAllowlistedDiagnostics() async throws {
        let context = makeContext(id: "target", title: "目标任务")
        let container = try makeContainer()
        let bridge = TestBridge(state: BridgeState(
            contexts: [context],
            outcomes: [.failed(exitCode: 9, message: "token=private path=/Users/example idea=secret")]
        ))
        let store = try IdeaDockStore(
            modelContainer: container,
            bridge: bridge,
            userDefaults: makeDefaults()
        )

        await store.bootstrap()
        store.setTarget("target")
        store.draftText = "不应出现在诊断中的正文"
        await store.queueCurrent()

        let capture = try XCTUnwrap(store.captures.first { $0.text == "不应出现在诊断中的正文" })
        XCTAssertEqual(capture.lastError, "Codex could not queue the message.")
        let attempts = try ModelContext(container).fetch(FetchDescriptor<DeliveryAttempt>())
        XCTAssertEqual(attempts.first { $0.captureID == capture.id }?.errorSummary, "Codex could not queue the message.")
    }

    func testUnknownQueueResultIsNotAutomaticallyRetried() async throws {
        let context = makeContext(id: "target", title: "目标任务")
        let state = BridgeState(
            contexts: [context],
            outcomes: [.unknown(message: "timeout"), .queued(exitCode: 0)]
        )
        let bridge = TestBridge(state: state)
        let store = try IdeaDockStore(
            modelContainer: makeContainer(),
            bridge: bridge,
            userDefaults: makeDefaults()
        )

        await store.bootstrap()
        store.setTarget("target")
        store.draftText = "结果不确定"
        await store.queueCurrent()

        let firstState: CaptureItem = try XCTUnwrap(store.captures.first { $0.text == "结果不确定" })
        XCTAssertEqual(firstState.status, .unknown)
        let queuedMessages = await state.queued
        XCTAssertEqual(queuedMessages.count, 1)
    }

    func testQueueDoesNotRequeueCaptureThatIsAlreadyQueued() async throws {
        let context = makeContext(id: "target", title: "目标任务")
        let state = BridgeState(
            contexts: [context],
            outcomes: [.queued(exitCode: 0), .queued(exitCode: 0)]
        )
        let store = try IdeaDockStore(
            modelContainer: makeContainer(),
            bridge: TestBridge(state: state),
            userDefaults: makeDefaults()
        )

        await store.bootstrap()
        store.setTarget("target")
        store.draftText = "只排队一次"
        let captureID = try XCTUnwrap(store.saveCurrent())

        await store.queue(captureID: captureID)
        await store.queue(captureID: captureID)

        let calls = await state.queued
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(store.captures.first { $0.id == captureID }?.status, .queued)
    }

    func testQueueDoesNotRequeueCaptureWithUnknownDeliveryResult() async throws {
        let context = makeContext(id: "target", title: "目标任务")
        let state = BridgeState(
            contexts: [context],
            outcomes: [
                .unknown(message: "结果待确认"),
                .queued(exitCode: 0)
            ]
        )
        let store = try IdeaDockStore(
            modelContainer: makeContainer(),
            bridge: TestBridge(state: state),
            userDefaults: makeDefaults()
        )

        await store.bootstrap()
        store.setTarget("target")
        store.draftText = "未知结果也只尝试一次"
        let captureID = try XCTUnwrap(store.saveCurrent())

        await store.queue(captureID: captureID)
        await store.queue(captureID: captureID)

        let calls = await state.queued
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(store.captures.first { $0.id == captureID }?.status, .unknown)
    }

    func testQueueDoesNotDuplicateCaptureWhileItIsQueueing() async throws {
        let context = makeContext(id: "target", title: "目标任务")
        let bridge = QueueGate(
            contexts: [context],
            outcome: .queued(exitCode: 0)
        )
        let store = try IdeaDockStore(
            modelContainer: makeContainer(),
            bridge: bridge,
            userDefaults: makeDefaults()
        )

        await store.bootstrap()
        store.setTarget("target")
        store.draftText = "进行中的投递"
        let queueCompletion = AsyncCompletion()
        let queueTask = Task {
            await store.queueCurrent()
            await queueCompletion.finish()
        }
        guard await bridge.waitUntilCalled() else {
            await bridge.release()
            queueTask.cancel()
            _ = await queueCompletion.wait()
            return XCTFail("Timed out waiting for the first queue delivery")
        }
        guard let captureID = store.captures.first(where: { $0.text == "进行中的投递" })?.id else {
            await bridge.release()
            queueTask.cancel()
            _ = await queueCompletion.wait()
            return XCTFail("The in-flight capture was not persisted")
        }
        let initialCaptureCount = store.captures.count

        await store.queue(captureID: captureID)
        let callsBeforeRelease = await bridge.recordedCalls()
        XCTAssertEqual(callsBeforeRelease.count, 1)
        XCTAssertEqual(store.captures.count, initialCaptureCount)
        XCTAssertEqual(store.captures.first { $0.id == captureID }?.status, .queueing)

        await bridge.release()
        guard await queueCompletion.wait() else {
            queueTask.cancel()
            return XCTFail("Timed out waiting for the queue operation to finish")
        }

        let calls = await bridge.recordedCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.message, "进行中的投递")
        XCTAssertEqual(calls.first?.threadID, "target")
    }

    func testInFlightQueueRejectsDraftRouteAndCaptureMutationsToProtectSnapshot() async throws {
        let source = makeContext(id: "source", title: "当前节目")
        let target = makeContext(id: "target", title: "Podcast Skill")
        let alternateSource = makeContext(id: "alternate-source", title: "另一个来源")
        let alternateTarget = makeContext(id: "alternate-target", title: "另一个目标")
        let bridge = QueueGate(
            contexts: [source, target, alternateSource, alternateTarget],
            outcome: .queued(exitCode: 0)
        )
        let store = try IdeaDockStore(
            modelContainer: makeContainer(),
            bridge: bridge,
            userDefaults: makeDefaults()
        )

        await store.bootstrap()
        store.setSource("source")
        store.setTarget("target")
        store.draftText = "原始文本"
        let queueCompletion = AsyncCompletion()
        let queueTask = Task {
            await store.queueCurrent()
            await queueCompletion.finish()
        }
        guard await bridge.waitUntilCalled() else {
            await bridge.release()
            queueTask.cancel()
            _ = await queueCompletion.wait()
            return XCTFail("Timed out waiting for the queue delivery")
        }
        guard let captureID = store.captures.first(where: { $0.text == "原始文本" })?.id else {
            await bridge.release()
            queueTask.cancel()
            _ = await queueCompletion.wait()
            return XCTFail("The in-flight capture was not persisted")
        }
        let initialCaptureCount = store.captures.count

        store.draftText = "并发编辑文本"
        store.setSource("alternate-source")
        store.setTarget("alternate-target")
        let savedID = store.saveCurrent()
        store.newCapture()
        store.updateText(captureID: captureID, text: "不应覆盖投递快照")
        store.archive(captureID)

        XCTAssertEqual(store.draftText, "原始文本")
        XCTAssertEqual(store.sourceThreadID, "source")
        XCTAssertEqual(store.targetThreadID, "target")
        XCTAssertNil(savedID)
        XCTAssertEqual(store.captures.count, initialCaptureCount)
        XCTAssertEqual(store.captures.first { $0.id == captureID }?.text, "原始文本")
        XCTAssertEqual(store.captures.first { $0.id == captureID }?.sourceThreadID, "source")
        XCTAssertEqual(store.captures.first { $0.id == captureID }?.targetThreadID, "target")
        XCTAssertEqual(store.captures.first { $0.id == captureID }?.status, .queueing)

        await bridge.release()
        guard await queueCompletion.wait() else {
            queueTask.cancel()
            return XCTFail("Timed out waiting for the queue operation to finish")
        }

        let calls = await bridge.recordedCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.message, "原始文本")
        XCTAssertEqual(calls.first?.threadID, "target")

        let queuedCapture = try XCTUnwrap(store.captures.first { $0.id == captureID })
        XCTAssertEqual(queuedCapture.text, "原始文本")
        XCTAssertEqual(queuedCapture.sourceThreadID, "source")
        XCTAssertEqual(queuedCapture.targetThreadID, "target")
        XCTAssertEqual(queuedCapture.status, .queued)
    }

    func testLegacyQueueingCaptureRecoversAsUnknownWithoutAutomaticRetry() async throws {
        let target = makeContext(id: "target", title: "目标任务")
        let container = try makeContainer()
        let capture = Capture(
            text: "应用退出前正在排队",
            sourceThreadID: "target",
            targetThreadID: "target",
            sourceTitle: "目标任务",
            targetTitle: "目标任务",
            status: .queueing
        )
        try seed(captures: [capture], in: container)

        let state = BridgeState(
            contexts: [target],
            outcomes: [.queued(exitCode: 0)]
        )
        let store = try IdeaDockStore(
            modelContainer: container,
            bridge: TestBridge(state: state),
            userDefaults: makeDefaults()
        )

        let recovered = try XCTUnwrap(store.captures.first { $0.id == capture.id })
        XCTAssertEqual(recovered.status, .unknown)

        await store.bootstrap()
        let callsAfterBootstrap = await state.queued
        XCTAssertTrue(callsAfterBootstrap.isEmpty)
        let auditContext = ModelContext(container)
        let recoveryAttempts = try auditContext.fetch(FetchDescriptor<DeliveryAttempt>())
            .filter { $0.captureID == capture.id }
        XCTAssertEqual(recoveryAttempts.count, 1)
        XCTAssertEqual(recoveryAttempts.first?.method, "codex-cli-interrupted")

        await store.queue(captureID: capture.id)
        let calls = await state.queued
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(store.captures.first { $0.id == capture.id }?.status, .unknown)
    }

    func testSavedCaptureCannotQueueToUnavailableHistoricalTarget() async throws {
        let staleTarget = makeContext(id: "stale-target", title: "已关闭任务")
        let replacement = makeContext(id: "replacement", title: "仍在运行的任务")
        let container = try makeContainer()
        let capture = Capture(
            text: "不能误投到其他任务",
            targetThreadID: staleTarget.id,
            targetTitle: staleTarget.title,
            status: .saved
        )
        try seed(
            captures: [capture],
            contexts: [
                WorkContext(
                    threadID: staleTarget.id,
                    title: staleTarget.title,
                    projectDirectory: staleTarget.projectDirectory,
                    projectID: staleTarget.projectID,
                    isAvailable: true,
                    recency: staleTarget.recency
                )
            ],
            in: container
        )
        let state = BridgeState(
            contexts: [replacement],
            outcomes: [.queued(exitCode: 0)]
        )
        let store = try IdeaDockStore(
            modelContainer: container,
            bridge: TestBridge(state: state),
            userDefaults: makeDefaults()
        )

        await store.refreshThreads()
        await store.queue(captureID: capture.id)

        let calls = await state.queued
        XCTAssertTrue(calls.isEmpty)
        let preservedCapture = try XCTUnwrap(store.captures.first { $0.id == capture.id })
        XCTAssertEqual(preservedCapture.status, .saved)
        XCTAssertEqual(preservedCapture.text, "不能误投到其他任务")
        XCTAssertEqual(preservedCapture.targetThreadID, staleTarget.id)
        XCTAssertEqual(preservedCapture.targetTitle, staleTarget.title)
        XCTAssertEqual(store.contexts.first { $0.id == staleTarget.id }?.isAvailable, false)
        XCTAssertEqual(store.notification?.kind, .warning)
    }

    func testSavedCaptureCanRetargetFromUnavailableTaskAndQueue() async throws {
        let staleTarget = makeContext(id: "stale-target", title: "已关闭任务")
        let replacement = makeContext(id: "replacement", title: "Podcast Skill")
        let container = try makeContainer()
        let capture = Capture(
            text: "把这条想法改投到仍可用的 Skill",
            targetThreadID: staleTarget.id,
            targetTitle: staleTarget.title,
            status: .saved
        )
        try seed(
            captures: [capture],
            contexts: [
                WorkContext(
                    threadID: staleTarget.id,
                    title: staleTarget.title,
                    isAvailable: true
                )
            ],
            in: container
        )
        let state = BridgeState(
            contexts: [replacement],
            outcomes: [.queued(exitCode: 0)]
        )
        let store = try IdeaDockStore(
            modelContainer: container,
            bridge: TestBridge(state: state),
            userDefaults: makeDefaults()
        )

        await store.refreshThreads()
        XCTAssertTrue(
            store.updateRoute(
                captureID: capture.id,
                sourceThreadID: nil,
                targetThreadID: replacement.id
            )
        )
        await store.queue(captureID: capture.id)

        let calls = await state.queued
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0, "把这条想法改投到仍可用的 Skill")
        XCTAssertEqual(calls.first?.1, replacement.id)
        let queuedCapture = try XCTUnwrap(store.captures.first { $0.id == capture.id })
        XCTAssertEqual(queuedCapture.targetThreadID, replacement.id)
        XCTAssertEqual(queuedCapture.targetTitle, replacement.title)
        XCTAssertEqual(queuedCapture.status, .queued)
    }

    func testBlankEditCannotOverwriteSavedCapture() throws {
        let store = try IdeaDockStore(
            modelContainer: makeContainer(),
            bridge: TestBridge(state: BridgeState()),
            userDefaults: makeDefaults()
        )
        store.draftText = "唯一保留的原文"
        let captureID = try XCTUnwrap(store.saveCurrent())

        XCTAssertFalse(store.updateText(captureID: captureID, text: " \n\t "))
        XCTAssertEqual(store.captures.first { $0.id == captureID }?.text, "唯一保留的原文")
        XCTAssertEqual(store.notification?.kind, .warning)
    }

    func testDeliveredCaptureRouteCannotBeChanged() throws {
        let container = try makeContainer()
        let capture = Capture(
            text: "已经发送",
            targetThreadID: "original",
            targetTitle: "原目标",
            status: .queued
        )
        try seed(captures: [capture], in: container)
        let store = try IdeaDockStore(
            modelContainer: container,
            bridge: TestBridge(state: BridgeState()),
            userDefaults: makeDefaults()
        )

        XCTAssertFalse(
            store.updateRoute(
                captureID: capture.id,
                sourceThreadID: nil,
                targetThreadID: "replacement"
            )
        )
        XCTAssertEqual(store.captures.first { $0.id == capture.id }?.targetThreadID, "original")
    }

    func testFlushDraftPersistsPendingDebouncedWrite() throws {
        let container = try makeContainer()
        let store = try IdeaDockStore(
            modelContainer: container,
            bridge: TestBridge(state: BridgeState()),
            userDefaults: makeDefaults()
        )
        store.draftText = "关闭窗口前必须落盘"

        store.flushDraft()

        let auditContext = ModelContext(container)
        let drafts = try auditContext.fetch(
            FetchDescriptor<Capture>(predicate: #Predicate { $0.statusRawValue == "draft" })
        )
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts.first?.text, "关闭窗口前必须落盘")
    }

    func testSuccessfulRefreshClearsPreviousAppServerWarning() async throws {
        let cached = makeContext(id: "cached", title: "缓存任务")
        let live = makeContext(id: "live", title: "实时任务")
        let container = try makeContainer()
        try seed(
            contexts: [
                WorkContext(
                    threadID: cached.id,
                    title: cached.title,
                    isAvailable: true
                )
            ],
            in: container
        )
        let store = try IdeaDockStore(
            modelContainer: container,
            bridge: RecoveringListBridge(contexts: [live]),
            userDefaults: makeDefaults()
        )

        await store.refreshThreads()
        XCTAssertEqual(store.notification?.kind, .warning)
        XCTAssertEqual(store.notification?.message, "Codex App Server 不可用，正在使用缓存任务。")

        await store.refreshThreads()
        XCTAssertNil(store.notification)
        XCTAssertEqual(store.contexts.first { $0.id == live.id }?.isAvailable, true)
    }

    func testRefreshDoesNotRewriteHistoricalCaptureTitles() async throws {
        let sourceID = "source"
        let targetID = "target"
        let container = try makeContainer()
        let capture = Capture(
            text: "保留想法产生时的上下文",
            sourceThreadID: sourceID,
            targetThreadID: targetID,
            sourceTitle: "录制节目时的标题",
            targetTitle: "迭代 Skill 时的标题",
            status: .saved
        )
        try seed(
            captures: [capture],
            contexts: [
                WorkContext(threadID: sourceID, title: "旧来源任务"),
                WorkContext(threadID: targetID, title: "旧目标任务")
            ],
            in: container
        )
        let bridge = TestBridge(state: BridgeState(contexts: [
            makeContext(id: sourceID, title: "重命名后的来源任务"),
            makeContext(id: targetID, title: "重命名后的目标任务")
        ]))
        let store = try IdeaDockStore(
            modelContainer: container,
            bridge: bridge,
            userDefaults: makeDefaults()
        )

        await store.refreshThreads()

        XCTAssertEqual(store.contexts.first { $0.id == sourceID }?.title, "重命名后的来源任务")
        XCTAssertEqual(store.contexts.first { $0.id == targetID }?.title, "重命名后的目标任务")
        XCTAssertEqual(store.captures.first { $0.id == capture.id }?.sourceTitle, "录制节目时的标题")
        XCTAssertEqual(store.captures.first { $0.id == capture.id }?.targetTitle, "迭代 Skill 时的标题")
    }

    func testSetPinnedTogglesLocalPinAndReordersContexts() async throws {
        let older = makeContext(
            id: "older",
            title: "Podcast Skill",
            recency: Date(timeIntervalSince1970: 100)
        )
        let newer = makeContext(
            id: "newer",
            title: "最近任务",
            recency: Date(timeIntervalSince1970: 1_000)
        )
        let store = try IdeaDockStore(
            modelContainer: makeContainer(),
            bridge: TestBridge(state: BridgeState(contexts: [older, newer])),
            userDefaults: makeDefaults()
        )

        await store.bootstrap()
        XCTAssertEqual(store.contexts.map(\.id), [newer.id, older.id])

        store.setPinned(true, for: older.id)
        XCTAssertEqual(store.contexts.map(\.id), [older.id, newer.id])
        XCTAssertEqual(store.contexts.first?.isPinned, true)

        store.setPinned(false, for: older.id)
        XCTAssertEqual(store.contexts.map(\.id), [newer.id, older.id])
        XCTAssertEqual(store.contexts.last?.isPinned, false)
    }

    func testRefreshPreservesLocalPinnedContextAndKeepsItFirst() async throws {
        let oldDate = Date(timeIntervalSince1970: 100)
        let newerDate = Date(timeIntervalSince1970: 10_000)
        let pinCandidate = makeContext(
            id: "local-pinned",
            title: "Podcast Skill",
            recency: oldDate
        )
        let newer = makeContext(
            id: "newer",
            title: "最近任务",
            pinned: false,
            recency: newerDate
        )
        let container = try makeContainer()
        let bridge = TestBridge(state: BridgeState(contexts: [
            WorkContextItem(
                id: pinCandidate.id,
                title: pinCandidate.title,
                projectDirectory: pinCandidate.projectDirectory,
                projectID: pinCandidate.projectID,
                isPinned: false,
                recency: pinCandidate.recency
            ),
            newer
        ]))
        do {
            let firstStore = try IdeaDockStore(
                modelContainer: container,
                bridge: bridge,
                userDefaults: makeDefaults()
            )
            await firstStore.refreshThreads()
            firstStore.setPinned(true, for: pinCandidate.id)
            XCTAssertEqual(firstStore.contexts.map(\.id), [pinCandidate.id, newer.id])
        }

        let restartedStore = try IdeaDockStore(
            modelContainer: container,
            bridge: bridge,
            userDefaults: makeDefaults()
        )
        await restartedStore.refreshThreads()

        XCTAssertEqual(restartedStore.contexts.map(\.id), [pinCandidate.id, newer.id])
        XCTAssertEqual(restartedStore.contexts.first?.isPinned, true)
        XCTAssertEqual(restartedStore.contexts.last?.isAvailable, true)
    }

    func testArchiveAndUndoRestorePreviousStatus() async throws {
        let bridge = TestBridge(state: BridgeState())
        let store = try IdeaDockStore(
            modelContainer: makeContainer(),
            bridge: bridge,
            userDefaults: makeDefaults()
        )
        store.draftText = "可归档想法"
        let captureID: UUID = try XCTUnwrap(store.saveCurrent())

        store.archive(captureID)
        XCTAssertEqual(store.captures.first { $0.id == captureID }?.status, .archived)
        store.undoArchive(captureID)
        XCTAssertEqual(store.captures.first { $0.id == captureID }?.status, .saved)
    }

    func testUndoArchiveAfterRestartRestoresQueuedStatus() throws {
        let container = try makeContainer()
        let capture = Capture(text: "已成功投递", status: .queued)
        let captureID = capture.id
        try seed(captures: [capture], in: container)
        let bridge = TestBridge(state: BridgeState())
        let firstStore = try IdeaDockStore(
            modelContainer: container,
            bridge: bridge,
            userDefaults: makeDefaults()
        )

        firstStore.archive(captureID)
        XCTAssertEqual(firstStore.captures.first { $0.id == captureID }?.status, .archived)

        let restartedStore = try IdeaDockStore(
            modelContainer: container,
            bridge: bridge,
            userDefaults: makeDefaults()
        )
        restartedStore.undoArchive(captureID)

        XCTAssertEqual(restartedStore.captures.first { $0.id == captureID }?.status, .queued)
    }

    func testUndoArchiveAfterRestartRestoresUnknownStatus() throws {
        let container = try makeContainer()
        let capture = Capture(
            text: "投递结果待确认",
            status: .unknown,
            lastError: "timeout"
        )
        let captureID = capture.id
        try seed(captures: [capture], in: container)
        let bridge = TestBridge(state: BridgeState())
        let firstStore = try IdeaDockStore(
            modelContainer: container,
            bridge: bridge,
            userDefaults: makeDefaults()
        )

        firstStore.archive(captureID)
        XCTAssertEqual(firstStore.captures.first { $0.id == captureID }?.status, .archived)

        let restartedStore = try IdeaDockStore(
            modelContainer: container,
            bridge: bridge,
            userDefaults: makeDefaults()
        )
        restartedStore.undoArchive(captureID)

        XCTAssertEqual(restartedStore.captures.first { $0.id == captureID }?.status, .unknown)
        XCTAssertEqual(restartedStore.captures.first { $0.id == captureID }?.lastError, "timeout")
    }

    func testArchivedDeliveredCaptureKeepsOriginalTextUntilUndo() throws {
        let container = try makeContainer()
        let capture = Capture(text: "已投递原文", status: .queued)
        try seed(captures: [capture], in: container)
        let store = try IdeaDockStore(
            modelContainer: container,
            bridge: TestBridge(state: BridgeState()),
            userDefaults: makeDefaults()
        )

        store.archive(capture.id)
        store.updateText(captureID: capture.id, text: "不应覆盖")

        let archived = try XCTUnwrap(store.captures.first { $0.id == capture.id })
        XCTAssertEqual(archived.status, .archived)
        XCTAssertEqual(archived.statusBeforeArchive, .queued)
        XCTAssertEqual(archived.text, "已投递原文")

        store.undoArchive(capture.id)
        let restored = try XCTUnwrap(store.captures.first { $0.id == capture.id })
        XCTAssertEqual(restored.status, .queued)
        XCTAssertEqual(restored.text, "已投递原文")
    }
}
