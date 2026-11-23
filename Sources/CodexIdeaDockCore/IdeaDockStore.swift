import Foundation
import Observation
import SwiftData

private enum PreferenceKey {
    static let activeDraftID = "activeDraftID"
    static let draftRecoveryBuffer = "draftRecoveryBuffer"
    static let sourceThreadID = "sourceThreadID"
    static let targetThreadID = "targetThreadID"
}

private enum ThreadRefreshMessage {
    static let unavailable = "暂时无法读取 Codex 任务。"
    static let usingCache = "Codex App Server 不可用，正在使用缓存任务。"
}

@MainActor
@Observable
public final class IdeaDockStore {
    public var draftText: String {
        didSet {
            guard !isApplyingPersistedDraft, draftText != oldValue else { return }
            guard !isQueueing else {
                applyDraftText(oldValue)
                return
            }
            stageDraftForPersistence()
        }
    }

    public private(set) var contexts: [WorkContextItem]
    public private(set) var captures: [CaptureItem]
    /// 已删除、还在垃圾箱里的想法（可恢复）。
    public private(set) var trashedCaptures: [CaptureItem] = []
    public private(set) var sourceThreadID: String?
    public private(set) var targetThreadID: String?
    public var searchText: String
    public var statusFilter: CaptureStatus?
    public private(set) var isLoadingContexts: Bool
    public private(set) var isQueueing: Bool
    public var notification: DockNotification?

    private let modelContext: ModelContext
    private let bridge: any CodexBridging
    private let defaults: UserDefaults
    private var activeDraftID: UUID?
    private var isApplyingPersistedDraft = false
    @ObservationIgnored private var draftPersistenceTask: Task<Void, Never>?
    @ObservationIgnored private var hasPendingDraftPersistence = false

    #if !FLOWCUE_APP_STORE
    public convenience init() throws {
        try self.init(
            modelContainer: IdeaDockPersistence.makeDefaultContainer(),
            bridge: CodexBridge(),
            userDefaults: .standard
        )
    }
    #endif

    public init(
        modelContainer: ModelContainer,
        bridge: any CodexBridging,
        userDefaults: UserDefaults
    ) throws {
        self.modelContext = ModelContext(modelContainer)
        self.bridge = bridge
        self.defaults = userDefaults
        self.draftText = ""
        self.contexts = []
        self.captures = []
        self.sourceThreadID = userDefaults.string(forKey: PreferenceKey.sourceThreadID)
        self.targetThreadID = userDefaults.string(forKey: PreferenceKey.targetThreadID)
        self.searchText = ""
        self.statusFilter = nil
        self.isLoadingContexts = false
        self.isQueueing = false

        try loadLocalState()
    }

    public var sourceContext: WorkContextItem? {
        guard let sourceThreadID else { return nil }
        return contexts.first { $0.id == sourceThreadID }
    }

    public var targetContext: WorkContextItem? {
        guard let targetThreadID else { return nil }
        return contexts.first { $0.id == targetThreadID }
    }

    public var pendingCount: Int {
        let persistedCount = captures.lazy.filter { capture in
            switch capture.status {
            case .draft, .queued, .archived:
                return false
            case .saved, .queueing, .failed, .unknown:
                return true
            }
        }.count
        let hasActiveDraft = !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let activeCaptureAlreadyCounted = activeDraftID.flatMap { draftID in
            captures.first { $0.id == draftID }
        }.map { $0.status != .draft } ?? false
        return persistedCount + (hasActiveDraft && !activeCaptureAlreadyCounted ? 1 : 0)
    }

    public var filteredCaptures: [CaptureItem] {
        let normalizedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return captures.filter { capture in
            guard capture.status != .draft else { return false }
            guard statusFilter == nil || capture.status == statusFilter else { return false }
            guard statusFilter == .archived || capture.status != .archived else { return false }
            guard !normalizedSearch.isEmpty else { return true }

            return capture.text.localizedCaseInsensitiveContains(normalizedSearch)
                || capture.sourceTitle?.localizedCaseInsensitiveContains(normalizedSearch) == true
                || capture.targetTitle?.localizedCaseInsensitiveContains(normalizedSearch) == true
        }
    }

    /// Draft recovery, task routing and delivery diagnostics remain device-local.
    public var sharedIdeas: [SharedIdea] {
        captures.filter { $0.status != .draft }.map {
            SharedIdea(id: $0.id, text: $0.text, createdAt: $0.createdAt,
                       updatedAt: $0.updatedAt, archived: $0.status == .archived)
        }
    }

    /// Apply an already reconciled sync projection atomically. Never executes an agent.
    public func applySharedIdeas(_ ideas: [SharedIdea]) throws {
        guard !isQueueing else { throw IdeaSyncError.synchronizationInProgress }
        do {
            for idea in ideas {
                guard !idea.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw IdeaSyncError.invalidRevision
                }
                if let capture = fetchCapture(id: idea.id) {
                    guard capture.status != .draft else { throw IdeaSyncError.protectedLocalNote }
                    let effectiveStatus = capture.status == .archived
                        ? capture.statusBeforeArchive ?? .unknown : capture.status
                    if capture.text != idea.text,
                       [.queued, .queueing, .unknown].contains(effectiveStatus) {
                        // Keep the incoming revision in the journal for manual resolution.
                        throw IdeaSyncError.protectedLocalNote
                    }
                    capture.text = idea.text
                    capture.updatedAt = idea.updatedAt
                    if idea.archived, capture.status != .archived {
                        capture.statusBeforeArchive = capture.status
                        capture.status = .archived
                    } else if !idea.archived, capture.status == .archived {
                        capture.status = capture.statusBeforeArchive ?? .saved
                        capture.statusBeforeArchive = nil
                    }
                } else {
                    modelContext.insert(Capture(
                        id: idea.id, text: idea.text, createdAt: idea.createdAt,
                        updatedAt: idea.updatedAt, status: idea.archived ? .archived : .saved,
                        statusBeforeArchive: idea.archived ? .saved : nil
                    ))
                }
            }
            try modelContext.save()
            try reloadCaptures()
        } catch {
            modelContext.rollback()
            try? reloadCaptures()
            throw error
        }
    }

    public func bootstrap() async {
        do {
            try loadLocalState()
        } catch {
            notification = DockNotification(kind: .error, message: "无法读取本地想法。")
        }
        await refreshThreads()
    }

    public func refreshThreads() async {
        guard !isLoadingContexts, !isQueueing else { return }
        let previousRefreshWarningID = Self.threadRefreshWarningID(in: notification)
        isLoadingContexts = true
        defer { isLoadingContexts = false }

        do {
            let liveContexts = try await bridge.listThreads()
            try mergeContexts(liveContexts)
            try reloadContexts()
            try refreshCaptureRoutes()
            try reloadCaptures()
            applyInitialContextIfNeeded()
            if notification?.id == previousRefreshWarningID {
                notification = nil
            }
        } catch {
            modelContext.rollback()
            do {
                try reloadContexts()
                applyInitialContextIfNeeded()
                notification = DockNotification(
                    kind: .warning,
                    message: contexts.isEmpty
                        ? ThreadRefreshMessage.unavailable
                        : ThreadRefreshMessage.usingCache
                )
            } catch {
                notification = DockNotification(kind: .error, message: "无法读取任务缓存。")
            }
        }
    }

    private static func threadRefreshWarningID(in notification: DockNotification?) -> UUID? {
        guard let notification, notification.kind == .warning else { return nil }
        guard notification.message == ThreadRefreshMessage.unavailable
            || notification.message == ThreadRefreshMessage.usingCache else {
            return nil
        }
        return notification.id
    }

    public func setSource(_ threadID: String?) {
        guard !isQueueing else { return }
        sourceThreadID = threadID
        defaults.set(threadID, forKey: PreferenceKey.sourceThreadID)
        markContextSelected(threadID)
        updateActiveDraftContext()
    }

    public func setTarget(_ threadID: String?) {
        guard !isQueueing else { return }
        targetThreadID = threadID
        defaults.set(threadID, forKey: PreferenceKey.targetThreadID)
        markContextSelected(threadID)
        updateActiveDraftContext()
    }

    public func setPinned(_ isPinned: Bool, for threadID: String) {
        guard !isQueueing else { return }
        let selectedID = threadID
        var descriptor = FetchDescriptor<WorkContext>(
            predicate: #Predicate { $0.threadID == selectedID }
        )
        descriptor.fetchLimit = 1
        guard let record = try? modelContext.fetch(descriptor).first else { return }

        record.isPinned = isPinned
        do {
            try modelContext.save()
            try reloadContexts()
        } catch {
            modelContext.rollback()
            try? reloadContexts()
            notification = DockNotification(kind: .error, message: "置顶状态未能保存。")
        }
    }

    @discardableResult
    public func saveCurrent() -> UUID? {
        guard !isQueueing else { return nil }
        cancelScheduledDraftPersistence()
        let text = draftText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let previousActiveDraftID = activeDraftID
        let capture = activeDraft() ?? makeDraft(text: text)
        capture.text = text
        applySelectedContexts(to: capture)
        capture.status = .saved
        capture.updatedAt = .now
        capture.lastError = nil

        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            restoreActiveDraftReference(previousActiveDraftID)
            try? reloadCaptures()
            stageDraftForPersistence()
            notification = DockNotification(kind: .error, message: "保存失败，内容仍保留在输入框中。")
            return nil
        }

        let savedID = capture.id
        clearActiveDraft()
        try? reloadCaptures()
        notification = DockNotification(kind: .success, message: "想法已保存到本地。")
        return savedID
    }

    @discardableResult
    public func saveMailTasks(_ tasks: [MailTriageTask]) -> Int {
        guard !isQueueing else { return 0 }
        let validTasks = tasks.filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !validTasks.isEmpty else { return 0 }

        let now = Date.now
        for task in validTasks {
            let dueDate = task.dueDate?.trimmingCharacters(in: .whitespacesAndNewlines)
            var lines = [
                "[邮件待办 · \(task.priority.displayName)] \(task.title)",
                "来源：\(task.source)",
                "判断理由：\(task.reason)"
            ]
            if let dueDate, !dueDate.isEmpty {
                lines.append("截止日期：\(dueDate)")
            }
            modelContext.insert(Capture(
                text: lines.joined(separator: "\n"),
                createdAt: now,
                updatedAt: now,
                status: .saved
            ))
        }

        do {
            try modelContext.save()
            try reloadCaptures()
            notification = DockNotification(kind: .success, message: "邮件待办已保存到本机收件箱。")
            return validTasks.count
        } catch {
            modelContext.rollback()
            try? reloadCaptures()
            notification = DockNotification(kind: .error, message: "修改未能保存。")
            return 0
        }
    }

    /// 仅用于截图/演示：丢弃当前草稿，不保存也不留痕。
    public func discardActiveDraft() {
        guard !isQueueing else { return }
        clearActiveDraft()
        draftText = ""
        notification = nil
    }

    public func newCapture() {
        guard !isQueueing else { return }
        if !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard saveCurrent() != nil else { return }
        } else {
            clearActiveDraft()
        }
        notification = nil
    }

    public func queueCurrent() async {
        guard !isQueueing else { return }
        cancelScheduledDraftPersistence()
        let text = draftText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            notification = DockNotification(kind: .warning, message: "请先输入想法。")
            return
        }
        guard let targetThreadID else {
            notification = DockNotification(kind: .warning, message: "请先选择目标任务。")
            return
        }
        guard isThreadAvailable(targetThreadID) else {
            notification = DockNotification(kind: .warning, message: "目标任务已不在 Codex 任务列表中。")
            return
        }

        let previousActiveDraftID = activeDraftID
        let capture = activeDraft() ?? makeDraft(text: text)
        capture.text = text
        applySelectedContexts(to: capture)
        isQueueing = true
        defer { isQueueing = false }
        capture.status = .queueing
        capture.updatedAt = .now
        capture.lastError = nil

        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            restoreActiveDraftReference(previousActiveDraftID)
            try? reloadCaptures()
            stageDraftForPersistence()
            notification = DockNotification(kind: .error, message: "无法保存本地副本，未向 Codex 投递。")
            return
        }
        markDraftPersistenceComplete()
        try? reloadCaptures()

        let outcome = await bridge.queue(message: text, to: targetThreadID)
        applyQueueOutcome(outcome, to: capture, clearDraftOnSuccess: true)
    }

    public func queue(captureID: UUID) async {
        guard !isQueueing else { return }
        guard let capture = fetchCapture(id: captureID) else { return }
        guard capture.status == .saved || capture.status == .failed else {
            notification = DockNotification(
                kind: .warning,
                message: capture.status == .unknown
                    ? "投递结果仍待确认，为避免重复消息未再次排队。"
                    : "这条想法当前不能再次排队。"
            )
            return
        }
        guard let targetThreadID = capture.targetThreadID else {
            notification = DockNotification(kind: .warning, message: "这条想法没有目标任务。")
            return
        }
        guard isThreadAvailable(targetThreadID) else {
            notification = DockNotification(kind: .warning, message: "目标任务已失效，请复制原文后选择新的任务。")
            return
        }
        let text = capture.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        isQueueing = true
        defer { isQueueing = false }
        capture.status = .queueing
        capture.updatedAt = .now
        capture.lastError = nil
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            try? reloadCaptures()
            notification = DockNotification(kind: .error, message: "无法保存投递状态，未向 Codex 投递。")
            return
        }
        try? reloadCaptures()

        let outcome = await bridge.queue(message: text, to: targetThreadID)
        applyQueueOutcome(outcome, to: capture, clearDraftOnSuccess: false)
    }

    @discardableResult
    public func updateText(captureID: UUID, text: String) -> Bool {
        guard !isQueueing else { return false }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            notification = DockNotification(kind: .warning, message: "内容不能为空，原文已保留。")
            return false
        }
        guard let capture = fetchCapture(id: captureID) else { return false }
        let effectiveStatus = capture.status == .archived
            ? capture.statusBeforeArchive ?? .unknown
            : capture.status
        guard effectiveStatus != .queued,
              effectiveStatus != .unknown,
              effectiveStatus != .queueing else {
            notification = DockNotification(kind: .warning, message: "已投递或待确认的原文不能修改。")
            return false
        }
        capture.text = text
        capture.updatedAt = .now
        if capture.status == .failed {
            capture.status = .saved
            capture.lastError = nil
        }
        do {
            try modelContext.save()
            try reloadCaptures()
            return true
        } catch {
            modelContext.rollback()
            try? reloadCaptures()
            notification = DockNotification(kind: .error, message: "修改未能保存。")
            return false
        }
    }

    /// iPhone 通过局域网推来的想法：按 id 幂等写入，重复推送不会产生副本。
    @discardableResult
    public func upsertRemoteIdea(_ idea: RemoteIdea) -> Bool {
        switch applyRemote(idea) {
        case .rejected:
            return false
        case .unchanged:
            return true
        case .applied:
            break
        }
        do {
            try modelContext.save()
            try reloadCaptures()
            return true
        } catch {
            modelContext.rollback()
            try? reloadCaptures()
            return false
        }
    }

    /// 拉取合并：和 upsertRemoteIdea 走同一套规则，只是调用方不同。
    @discardableResult
    public func mergePulledIdeas(_ ideas: [RemoteIdea]) -> Int {
        var merged = 0
        for idea in ideas where applyRemote(idea) == .applied { merged += 1 }
        guard merged > 0 else { return 0 }
        do {
            try modelContext.save()
            try reloadCaptures()
            return merged
        } catch {
            modelContext.rollback()
            try? reloadCaptures()
            return 0
        }
    }

    #if DEBUG
    /// 仅用于测试：直接改状态，避免在单测里驱动整个队列流程。
    public func setStatusForTesting(captureID: UUID, status: CaptureStatus) {
        guard let capture = fetchCapture(id: captureID) else { return }
        capture.status = status
        try? modelContext.save()
        try? reloadCaptures()
    }

    /// 仅用于 UI 测试：插入几条可预测的想法，方便断言列表行为。
    public func seedUIIdeasIfNeeded() {
        let prefix = "UITest idea"
        // 逐条补齐，而不是「有就整体跳过」——否则上一轮只种了 6 条，
        // 这一轮要 20 条时会以为已经种过。
        for index in 1...20 {
            let text = "\(prefix) \(index)"
            guard !captures.contains(where: { $0.text == text }) else { continue }
            modelContext.insert(Capture(text: text, status: .saved))
        }
        try? modelContext.save()
        try? reloadCaptures()
    }
    #endif

    /// 从垃圾箱恢复：清掉墓碑，恢复时间往前走，让对端也跟着恢复。
    @discardableResult
    public func restore(_ captureID: UUID) -> Bool {
        guard let capture = fetchCapture(id: captureID) else { return false }
        capture.deletedAt = nil
        capture.updatedAt = Date.now
        do {
            try modelContext.save()
            try reloadCaptures()
            notification = DockNotification(kind: .success, message: "已恢复。")
            return true
        } catch {
            modelContext.rollback()
            try? reloadCaptures()
            return false
        }
    }

    /// 彻底删除（清空垃圾箱用）。对端已持有墓碑，不会再把它当新想法插回来。
    @discardableResult
    public func deletePermanently(_ captureID: UUID) -> Bool {
        guard let capture = fetchCapture(id: captureID) else { return false }
        modelContext.delete(capture)
        do {
            try modelContext.save()
            try reloadCaptures()
            return true
        } catch {
            modelContext.rollback()
            try? reloadCaptures()
            return false
        }
    }

    /// 同步用的整库快照：包含墓碑（deletedAt 非空的也要给对端），
    /// 这样删除才能传播出去。
    public func syncSnapshot() -> [RemoteIdea] {
        let all = (try? modelContext.fetch(FetchDescriptor<Capture>())) ?? []
        return all.map { capture in
            RemoteIdea(
                id: capture.id,
                text: capture.text,
                createdAt: capture.createdAt,
                updatedAt: capture.updatedAt,
                status: capture.statusRawValue,
                deletedAt: capture.deletedAt
            )
        }
    }

    private enum RemoteApplyResult {
        case rejected   // 空内容且不是墓碑，直接拒绝
        case unchanged  // 本地更新或内容一致，什么都不用做
        case applied    // 已修改本地，需要保存
    }

    /// 一条远端想法怎么合并：时间更新的赢；墓碑优先于正文。
    private func applyRemote(_ idea: RemoteIdea) -> RemoteApplyResult {
        let text = idea.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteTime = max(idea.updatedAt, idea.deletedAt ?? .distantPast)

        if let capture = fetchCapture(id: idea.id) {
            // 正在排队/投递中的想法不能被另一台设备覆盖：
            // 正文和状态都以本机为准，否则队列会和实际发送的内容对不上。
            if capture.status == .queued || capture.status == .queueing,
               idea.deletedAt == nil {
                return .unchanged
            }
            guard remoteTime > capture.updatedAt else { return .unchanged }
            capture.updatedAt = remoteTime
            if let deletedAt = idea.deletedAt {
                capture.deletedAt = deletedAt
            } else {
                capture.deletedAt = nil
                if !text.isEmpty { capture.text = text }
            }
            if capture.deletedAt == nil {
                // 草稿只属于设备本地：手机新建的想法状态是 draft，直接照搬会让它
                // 在 Mac 列表里消失（filteredCaptures 不显示草稿）。
                let incoming = idea.status.flatMap(CaptureStatus.init(rawValue:))
                if let incoming, incoming != .draft {
                    capture.status = incoming
                } else if capture.status == .draft, !text.isEmpty {
                    capture.status = .saved
                }
            }
            return .applied
        }

        guard !text.isEmpty || idea.deletedAt != nil else { return .rejected }
        modelContext.insert(Capture(
            id: idea.id,
            text: text,
            createdAt: idea.createdAt,
            updatedAt: remoteTime,
            status: .saved,
            deletedAt: idea.deletedAt
        ))
        return .applied
    }

    @discardableResult
    public func updateRoute(
        captureID: UUID,
        sourceThreadID: String?,
        targetThreadID: String?
    ) -> Bool {
        guard !isQueueing else { return false }
        guard let capture = fetchCapture(id: captureID) else { return false }
        guard capture.status == .saved || capture.status == .failed else {
            notification = DockNotification(kind: .warning, message: "当前状态下不能修改任务关联。")
            return false
        }
        guard isValidRouteSelection(sourceThreadID, existingThreadID: capture.sourceThreadID),
              isValidRouteSelection(targetThreadID, existingThreadID: capture.targetThreadID) else {
            notification = DockNotification(kind: .warning, message: "请选择仍可用的 Codex 任务。")
            return false
        }

        if capture.sourceThreadID != sourceThreadID {
            capture.sourceThreadID = sourceThreadID
            capture.sourceTitle = contextTitle(for: sourceThreadID)
        }
        if capture.targetThreadID != targetThreadID {
            capture.targetThreadID = targetThreadID
            capture.targetTitle = contextTitle(for: targetThreadID)
            if capture.status == .failed {
                capture.status = .saved
                capture.lastError = nil
            }
        }
        capture.updatedAt = .now

        do {
            try modelContext.save()
            try reloadCaptures()
            notification = DockNotification(kind: .success, message: "任务关联已更新。")
            return true
        } catch {
            modelContext.rollback()
            try? reloadCaptures()
            notification = DockNotification(kind: .error, message: "任务关联未能保存。")
            return false
        }
    }

    public func archive(_ captureID: UUID) {
        guard !isQueueing else { return }
        guard let capture = fetchCapture(id: captureID), capture.status != .archived else { return }
        capture.statusBeforeArchive = capture.status
        capture.status = .archived
        capture.updatedAt = .now
        do {
            try modelContext.save()
            try reloadCaptures()
            notification = DockNotification(kind: .success, message: "已归档，可立即撤销。")
        } catch {
            modelContext.rollback()
            try? reloadCaptures()
            notification = DockNotification(kind: .error, message: "归档失败。")
        }
    }

    public func undoArchive(_ captureID: UUID) {
        guard !isQueueing else { return }
        guard let capture = fetchCapture(id: captureID), capture.status == .archived else { return }
        let previousStatus = capture.statusBeforeArchive ?? .unknown
        capture.status = previousStatus == .archived ? .unknown : previousStatus
        capture.statusBeforeArchive = nil
        capture.updatedAt = .now
        do {
            try modelContext.save()
            try reloadCaptures()
            notification = DockNotification(kind: .success, message: "已撤销归档。")
        } catch {
            modelContext.rollback()
            try? reloadCaptures()
            notification = DockNotification(kind: .error, message: "撤销失败。")
        }
    }

    public func dismissNotification() {
        notification = nil
    }

    public func flushDraft() {
        guard !isQueueing, hasPendingDraftPersistence else { return }
        cancelScheduledDraftPersistence()
        persistDraft()
    }

    public func captureText(for captureID: UUID) -> String? {
        fetchCapture(id: captureID)?.text
    }

    private func loadLocalState() throws {
        try reloadContexts()
        try recoverInterruptedQueues()
        try reloadCaptures()

        if let storedID = defaults.string(forKey: PreferenceKey.activeDraftID),
           let draftID = UUID(uuidString: storedID),
           let draft = fetchCapture(id: draftID),
           draft.status == .draft || draft.status == .failed {
            activeDraftID = draftID
            applyDraftText(draft.text)
            sourceThreadID = draft.sourceThreadID ?? sourceThreadID
            targetThreadID = draft.targetThreadID ?? targetThreadID
        } else if let draft = newestDraft() {
            activeDraftID = draft.id
            defaults.set(draft.id.uuidString, forKey: PreferenceKey.activeDraftID)
            applyDraftText(draft.text)
            sourceThreadID = draft.sourceThreadID ?? sourceThreadID
            targetThreadID = draft.targetThreadID ?? targetThreadID
        }

        applyInitialContextIfNeeded()
        try restoreDraftRecoveryBufferIfNeeded()
    }

    private func applyDraftText(_ text: String) {
        isApplyingPersistedDraft = true
        draftText = text
        isApplyingPersistedDraft = false
    }

    private func stageDraftForPersistence() {
        defaults.set(draftText, forKey: PreferenceKey.draftRecoveryBuffer)
        hasPendingDraftPersistence = true
        draftPersistenceTask?.cancel()
        draftPersistenceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            persistDraft()
        }
    }

    private func cancelScheduledDraftPersistence() {
        draftPersistenceTask?.cancel()
        draftPersistenceTask = nil
    }

    private func markDraftPersistenceComplete() {
        cancelScheduledDraftPersistence()
        defaults.removeObject(forKey: PreferenceKey.draftRecoveryBuffer)
        hasPendingDraftPersistence = false
    }

    private func persistDraft() {
        guard hasPendingDraftPersistence else { return }
        let previousActiveDraftID = activeDraftID
        let capture: Capture
        if let existing = activeDraft() {
            capture = existing
        } else {
            capture = makeDraft(text: draftText)
        }

        capture.text = draftText
        capture.updatedAt = .now
        capture.status = .draft
        capture.lastError = nil
        applySelectedContexts(to: capture)

        do {
            try modelContext.save()
            try reloadCaptures()
            markDraftPersistenceComplete()
        } catch {
            modelContext.rollback()
            restoreActiveDraftReference(previousActiveDraftID)
            try? reloadCaptures()
            notification = DockNotification(kind: .error, message: "草稿自动保存失败。")
        }
    }

    private func makeDraft(text: String) -> Capture {
        let now = Date.now
        let capture = Capture(
            text: text,
            sourceThreadID: sourceThreadID,
            targetThreadID: targetThreadID,
            sourceTitle: contextTitle(for: sourceThreadID),
            targetTitle: contextTitle(for: targetThreadID),
            createdAt: now,
            updatedAt: now,
            status: .draft
        )
        modelContext.insert(capture)
        activeDraftID = capture.id
        defaults.set(capture.id.uuidString, forKey: PreferenceKey.activeDraftID)
        return capture
    }

    private func clearActiveDraft() {
        markDraftPersistenceComplete()
        activeDraftID = nil
        defaults.removeObject(forKey: PreferenceKey.activeDraftID)
        applyDraftText("")
    }

    private func restoreActiveDraftReference(_ draftID: UUID?) {
        activeDraftID = draftID
        if let draftID {
            defaults.set(draftID.uuidString, forKey: PreferenceKey.activeDraftID)
        } else {
            defaults.removeObject(forKey: PreferenceKey.activeDraftID)
        }
    }

    private func activeDraft() -> Capture? {
        guard let activeDraftID else { return nil }
        guard let capture = fetchCapture(id: activeDraftID),
              capture.status == .draft || capture.status == .failed else {
            return nil
        }
        return capture
    }

    private func newestDraft() -> Capture? {
        let descriptor = FetchDescriptor<Capture>(
            predicate: #Predicate { $0.statusRawValue == "draft" }
        )
        return try? modelContext.fetch(descriptor).max { $0.updatedAt < $1.updatedAt }
    }

    /// 删除改成写墓碑（软删）。硬删会让另一台设备永远不知道这条已经没了，
    /// 下次拉取又会把它当“缺失”重新插回来。
    @discardableResult
    public func delete(_ captureID: UUID) -> Bool {
        guard let capture = fetchCapture(id: captureID) else { return false }
        let now = Date.now
        capture.deletedAt = now
        capture.updatedAt = now
        do {
            try modelContext.save()
            try reloadCaptures()
            notification = DockNotification(kind: .success, message: "已删除。")
            return true
        } catch {
            modelContext.rollback()
            try? reloadCaptures()
            notification = DockNotification(kind: .error, message: "删除失败。")
            return false
        }
    }

    private func fetchCapture(id: UUID) -> Capture? {
        var descriptor = FetchDescriptor<Capture>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private func applySelectedContexts(to capture: Capture) {
        capture.sourceThreadID = sourceThreadID
        capture.targetThreadID = targetThreadID
        capture.sourceTitle = contextTitle(for: sourceThreadID)
        capture.targetTitle = contextTitle(for: targetThreadID)
    }

    private func updateActiveDraftContext() {
        guard let capture = activeDraft() else { return }
        applySelectedContexts(to: capture)
        capture.updatedAt = .now
        do {
            try modelContext.save()
            try reloadCaptures()
        } catch {
            modelContext.rollback()
            try? reloadCaptures()
            notification = DockNotification(kind: .error, message: "任务上下文未能保存。")
        }
    }

    private func applyQueueOutcome(
        _ outcome: QueueDeliveryOutcome,
        to capture: Capture,
        clearDraftOnSuccess: Bool
    ) {
        let attempt: DeliveryAttempt
        switch outcome {
        case .queued(let exitCode):
            capture.status = .queued
            capture.lastError = nil
            attempt = DeliveryAttempt(
                captureID: capture.id,
                method: "codex-cli",
                exitCode: exitCode
            )
            notification = DockNotification(kind: .success, message: "已排入目标 Codex 任务的下一轮。")
        case .failed(let exitCode, let message):
            let summary = QueueDeliveryDiagnostic.allowlistedSummary(
                message,
                fallback: .queueFailed
            )
            capture.status = .failed
            capture.lastError = summary
            attempt = DeliveryAttempt(
                captureID: capture.id,
                method: "codex-cli",
                exitCode: exitCode,
                errorSummary: summary
            )
            notification = DockNotification(kind: .error, message: "排队失败，原文已保留。")
        case .unknown(let message):
            let summary = QueueDeliveryDiagnostic.allowlistedSummary(
                message,
                fallback: .confirmationTimedOut
            )
            capture.status = .unknown
            capture.lastError = summary
            attempt = DeliveryAttempt(
                captureID: capture.id,
                method: "codex-cli",
                errorSummary: summary
            )
            notification = DockNotification(kind: .warning, message: "投递结果待确认，已停止自动重试。")
        }

        capture.updatedAt = .now
        modelContext.insert(attempt)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            try? reloadCaptures()
            if clearDraftOnSuccess {
                clearActiveDraft()
            }
            notification = DockNotification(kind: .error, message: "投递完成，但本地状态保存失败。")
            return
        }

        if clearDraftOnSuccess {
            switch outcome {
            case .queued, .unknown:
                clearActiveDraft()
            case .failed:
                break
            }
        }
        try? reloadCaptures()
    }

    private func contextTitle(for threadID: String?) -> String? {
        guard let threadID else { return nil }
        return contexts.first { $0.id == threadID }?.title
    }

    private func isThreadAvailable(_ threadID: String) -> Bool {
        contexts.first { $0.id == threadID }?.isAvailable == true
    }

    private func isValidRouteSelection(
        _ threadID: String?,
        existingThreadID: String?
    ) -> Bool {
        guard let threadID else { return true }
        return threadID == existingThreadID || isThreadAvailable(threadID)
    }

    private func restoreDraftRecoveryBufferIfNeeded() throws {
        guard defaults.object(forKey: PreferenceKey.draftRecoveryBuffer) != nil else { return }
        let recoveredText = defaults.string(forKey: PreferenceKey.draftRecoveryBuffer) ?? ""
        let capture = activeDraft() ?? makeDraft(text: recoveredText)
        capture.text = recoveredText
        capture.updatedAt = .now
        capture.status = .draft
        capture.lastError = nil
        applySelectedContexts(to: capture)
        try modelContext.save()
        try reloadCaptures()
        applyDraftText(recoveredText)
        defaults.removeObject(forKey: PreferenceKey.draftRecoveryBuffer)
        hasPendingDraftPersistence = false
    }

    private func applyInitialContextIfNeeded() {
        let availableContexts = contexts.filter(\.isAvailable)
        guard let initial = availableContexts.first(where: \.isPinned) ?? availableContexts.first else { return }
        if sourceThreadID == nil {
            setSource(initial.id)
        }
        if targetThreadID == nil {
            setTarget(sourceThreadID ?? initial.id)
        }
    }

    private func markContextSelected(_ threadID: String?) {
        guard let threadID else { return }
        let selectedID = threadID
        var descriptor = FetchDescriptor<WorkContext>(
            predicate: #Predicate { $0.threadID == selectedID }
        )
        descriptor.fetchLimit = 1
        guard let record = try? modelContext.fetch(descriptor).first else { return }
        record.lastSelectedAt = .now
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
        }
    }

    private func mergeContexts(_ newContexts: [WorkContextItem]) throws {
        let existing = try modelContext.fetch(FetchDescriptor<WorkContext>())
        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.threadID, $0) })

        for record in existing {
            record.isAvailable = false
        }

        for item in newContexts {
            if let record = existingByID[item.id] {
                record.title = item.title
                record.projectDirectory = item.projectDirectory
                record.projectID = item.projectID
                record.isAvailable = true
                record.recency = item.recency
            } else {
                modelContext.insert(
                    WorkContext(
                        threadID: item.id,
                        title: item.title,
                        projectDirectory: item.projectDirectory,
                        projectID: item.projectID,
                        isPinned: item.isPinned,
                        isAvailable: true,
                        recency: item.recency
                    )
                )
            }
        }
        try modelContext.save()
    }

    private func recoverInterruptedQueues() throws {
        let records = try modelContext.fetch(
            FetchDescriptor<Capture>(
                predicate: #Predicate { $0.statusRawValue == "queueing" }
            )
        )
        guard !records.isEmpty else { return }

        let summary = "应用在等待 Codex 确认时中断；请先到目标任务确认，避免重复投递。"
        for record in records {
            record.status = .unknown
            record.lastError = summary
            record.updatedAt = .now
            modelContext.insert(
                DeliveryAttempt(
                    captureID: record.id,
                    method: "codex-cli-interrupted",
                    errorSummary: summary
                )
            )
        }
        try modelContext.save()
    }

    private func refreshCaptureRoutes() throws {
        let records = try modelContext.fetch(FetchDescriptor<Capture>())
        var didChange = false
        for record in records {
            let sourceTitle = contextTitle(for: record.sourceThreadID)
            let targetTitle = contextTitle(for: record.targetThreadID)
            if record.sourceTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
               let sourceTitle {
                record.sourceTitle = sourceTitle
                didChange = true
            }
            if record.targetTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
               let targetTitle {
                record.targetTitle = targetTitle
                didChange = true
            }
        }
        if didChange {
            try modelContext.save()
        }
    }

    private func reloadContexts() throws {
        contexts = try modelContext.fetch(FetchDescriptor<WorkContext>())
            .sorted {
                if $0.isAvailable != $1.isAvailable {
                    return $0.isAvailable && !$1.isAvailable
                }
                if $0.isPinned != $1.isPinned {
                    return $0.isPinned && !$1.isPinned
                }
                if $0.recency != $1.recency {
                    return $0.recency > $1.recency
                }
                return $0.threadID < $1.threadID
            }
            .map(\.item)
    }

    private func reloadCaptures() throws {
        let all = try modelContext.fetch(FetchDescriptor<Capture>())
        captures = all
            .filter { $0.deletedAt == nil }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map(\.item)
        trashedCaptures = all
            .compactMap { capture -> (Capture, Date)? in
                guard let deletedAt = capture.deletedAt else { return nil }
                return (capture, deletedAt)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0.item)
    }

}
