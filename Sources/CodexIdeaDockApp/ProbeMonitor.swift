import AppKit
import Foundation
#if SWIFT_PACKAGE
import CodexIdeaDockCore
#endif

/// 轮询探针：DSH 待审 + Claude 最新回复。
/// Codex 不走这里——它用 Stop hook 推送，避免每 15 秒起一个 app-server。
@MainActor
final class ProbeMonitor {
    private var task: Task<Void, Never>?
    private var lastAssistantID: [String: String] = [:]
    private var lastDSHActivity: [String: Date] = [:]
    private var lastDSHNotice: [String: Date] = [:]
    /// DSH 在前台时不弹通知：用户已经在看了
    private let dshBundle = "com.deepseek.dsh"
    private let dshReader = DSHSessionReader()
    private var knownApprovals: Set<String> = []
    /// 只在第一次轮询时建立基线。用 knownApprovals.isEmpty 判断是错的：
    /// 启动后没有待审批时它一直是空集，于是「启动后的第一条审批」会被
    /// 当成基线吞掉，既不推手机也不弹桌面通知。
    private var hasSeededApprovals = false
    private var knownQuestions: Set<String> = []
    private var hasSeededQuestions = false

    /// 待审批数量变化（喂给菜单栏角标）
    var onApprovalsCount: ((Int) -> Void)?

    private let service = AgentService.default
    private let bridge = DSHBridgeClient()

    private let approvalInterval: Duration = .seconds(15)
    private let messageInterval: Duration = .seconds(30)

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                // 审批每 3 秒查一次：这是本机回环请求，几乎不花钱，
                // 但决定了审批推到手机的快慢。其它探测仍保持 15 秒。
                await self?.pollApprovals()
                await self?.pollQuestions()
                if tick % 5 == 0 { await self?.pollClaude() }
                if tick % 5 == 2 { await self?.pollDSH() }
                tick += 1
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func pollApprovals() async {
        guard bridge.isConfigured, let pending = try? await bridge.pending() else { return }
        let ids = Set(pending.map { $0.id })
        if !hasSeededApprovals {
            // 只在进程启动后的第一次轮询记基线，避免启动瞬间刷一屏通知。
            hasSeededApprovals = true
            knownApprovals = ids
            await MainActor.run { self.onApprovalsCount?(ids.count) }
            return
        }
        let fresh = ids.subtracting(knownApprovals)
        knownApprovals = ids
        await MainActor.run { self.onApprovalsCount?(ids.count) }
        if !fresh.isEmpty {
            await MainActor.run { NotificationService.shared.postApprovals(count: fresh.count) }
            await pushApprovals(fresh: fresh, pending: pending)
        }
    }

    /// 有人在等你回答问题时推一条（和审批分开，方便区别对待）。
    private func pollQuestions() async {
        guard bridge.isConfigured, let batches = try? await bridge.questions() else { return }
        let ids = Set(batches.map { $0.id })
        if !hasSeededQuestions {
            hasSeededQuestions = true
            knownQuestions = ids
            return
        }
        let fresh = batches.filter { !knownQuestions.contains($0.id) }
        knownQuestions = ids
        guard let first = fresh.first,
              let question = first.questions.first,
              let settings = APNsSettings.load(),
              let deviceToken = UserDefaults.standard.string(forKey: "FlowCue.pushDeviceToken"),
              !deviceToken.isEmpty else { return }
        let environment = UserDefaults.standard.string(forKey: "FlowCue.pushEnvironment")
        let sender = settings.sender(environmentOverride: environment)
        guard sender.isConfigured else { return }
        try? await sender.send(
            deviceToken: deviceToken,
            title: "有任务在等你回答",
            body: question.title,
            threadID: "dsh-questions"
        )
    }

    /// 给手机推一条 APNs 通知：锁屏、后台也能看到。
    /// 没配置密钥或手机没上报 token 时静默跳过，不影响桌面逻辑。
    private func pushApprovals(fresh: Set<String>, pending: [DSHRemoteApproval]) async {
        guard let settings = APNsSettings.load(),
              let deviceToken = UserDefaults.standard.string(forKey: "FlowCue.pushDeviceToken"),
              !deviceToken.isEmpty,
              let first = pending.first(where: { fresh.contains($0.id) }) else { return }
        let environment = UserDefaults.standard.string(forKey: "FlowCue.pushEnvironment")
        let sender = settings.sender(environmentOverride: environment)
        guard sender.isConfigured else { return }
        let title = fresh.count > 1 ? "\(fresh.count) 个 DSH 待审批" : "DSH 待审批"
        try? await sender.send(
            deviceToken: deviceToken,
            title: title,
            body: first.title,
            threadID: "dsh-approvals"
        )
    }

    /// DSH 没有可读的对话接口，只能看会话文件的修改时间。
    /// 用 20 秒粒度 + 每会话去重，避免同一条刷屏。
    private func pollDSH() async {
        let frontmost = await MainActor.run { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
        guard frontmost != dshBundle else {
            // DSH 正在前台：只更新基线，不发通知
            for session in dshReader.sessions(limit: 10) {
                lastDSHActivity[session.id] = session.updatedAt
            }
            return
        }
        let sessions = dshReader.sessions(limit: 10)
        for session in sessions {
            let previous = lastDSHActivity[session.id]
            lastDSHActivity[session.id] = session.updatedAt
            guard let previous, session.updatedAt > previous else { continue }
            guard session.updatedAt.timeIntervalSinceNow > -120 else { continue }  // 只看两分钟内的新活动
            // 同一会话 60 秒内只提醒一次
            if let notified = lastDSHNotice[session.id],
               Date().timeIntervalSince(notified) < 60 { continue }
            lastDSHNotice[session.id] = Date()
            let title = session.title
            await MainActor.run {
                NotificationService.shared.postTurnFinished(
                    agent: "DSH",
                    sessionTitle: title,
                    snippet: L10n.text("有新回复"),
                    agentID: "dsh",
                    sessionID: session.id
                )
            }
        }
    }

    private func pollClaude() async {
        // 装了 Stop hook 就由事件推送，不再轮询
        guard !ClaudeHooks.isInstalled() else { return }
        guard let adapter = service.adapter(for: "claude"),
              let sessions = try? await service.sessions(for: "claude", limit: 5) else { return }
        for session in sessions {
            guard let messages = try? await service.messages(session, limit: 5),
                  let last = messages.last(where: { $0.role == .assistant }) else { continue }
            let previous = lastAssistantID[session.id]
            lastAssistantID[session.id] = last.id
            guard let previous, previous != last.id else { continue }
            let snippet = last.text
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            await MainActor.run {
                NotificationService.shared.postTurnFinished(
                    agent: "Claude Code",
                    sessionTitle: session.title,
                    snippet: String(snippet.prefix(90)),
                    agentID: "claude",
                    sessionID: session.id
                )
            }
        }
    }
}
