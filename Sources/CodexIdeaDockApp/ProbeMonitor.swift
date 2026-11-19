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
    private var knownApprovals: Set<String> = []

    private let service = AgentService.default
    private let bridge = DSHBridgeClient()

    private let approvalInterval: Duration = .seconds(15)
    private let messageInterval: Duration = .seconds(30)

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                await self?.pollApprovals()
                if tick % 2 == 0 { await self?.pollClaude() }
                tick += 1
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
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
        if knownApprovals.isEmpty {
            // 首次只记基线，避免启动瞬间刷一屏通知
            knownApprovals = ids
            return
        }
        let fresh = ids.subtracting(knownApprovals)
        knownApprovals = ids
        if !fresh.isEmpty {
            await MainActor.run { NotificationService.shared.postApprovals(count: fresh.count) }
        }
    }

    private func pollClaude() async {
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
