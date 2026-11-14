import SwiftUI
#if SWIFT_PACKAGE
import CodexIdeaDockCore
#endif

/// 三栏：agent → 会话 → 对话。目前只有 Claude Code 接了适配器。
struct AgentBrowserView: View {
    @State private var agents: [AgentRecord] = []
    @State private var selectedAgent: AgentRecord?
    @State private var sessions: [AgentSession] = []
    @State private var selectedSession: AgentSession?
    @State private var messages: [AgentMessage] = []
    @State private var note: String?

    private func adapter(for id: String) -> AgentAdapter? {
        switch id {
        case "claude": ClaudeCodeAdapter()
        case "codex": CodexAgentAdapter()
        default: nil
        }
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                agentColumn.frame(width: 190).clipped()
                Divider()
                sessionColumn.frame(width: 240).clipped()
                Divider()
                messageColumn
                    .frame(width: max(200, geo.size.width - 432), height: geo.size.height)
                    .clipped()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if agents.isEmpty { agents = AgentDiscovery.scan() }
            if selectedAgent == nil { select(agents.first { $0.capabilities.contains(.session) }) }
        }
    }

    // MARK: 列

    private var agentColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.text("Agent")).font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 6)
            ScrollView(.vertical) {
                LazyVStack(spacing: 2) {
                    ForEach(agents) { agent in
                        Button { select(agent) } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(agent.capabilities.contains(.session)
                                          ? Color(hex: FlowCueTokens.airyDark.success)
                                          : Color(hex: FlowCueTokens.airyDark.textTertiary))
                                    .frame(width: 6, height: 6)
                                Text(agent.displayName).font(.callout).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(selectedAgent?.id == agent.id ? Color.accentColor.opacity(0.15) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 6)
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    private var sessionColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(selectedAgent?.displayName ?? L10n.text("会话"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { reloadSessions() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).font(.caption)
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 6)

            if let note {
                Text(note).font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }

            ScrollView(.vertical) {
                LazyVStack(spacing: 2) {
                    ForEach(sessions) { session in
                        Button { select(session) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.title).font(.callout).lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Text(session.updatedAt, format: .relative(presentation: .named))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(selectedSession?.id == session.id ? Color.accentColor.opacity(0.15) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 6)
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    private var messageColumn: some View {
        VStack(spacing: 0) {
            if let session = selectedSession {
                Text(session.title)
                    .font(.headline).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(messages) { message in bubble(message) }
                    }
                    .padding(14)
                }
            } else {
                VStack {
                    Spacer()
                    Text(L10n.text("选择左侧会话查看对话"))
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func bubble(_ message: AgentMessage) -> some View {
        let isUser = message.role == .user
        return HStack {
            if isUser { Spacer(minLength: 40) }
            Text(message.text)
                .font(.callout)
                .textSelection(.enabled)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: FlowCueMetrics.radiusInline, style: .continuous)
                        .fill(isUser ? Color(hex: FlowCueTokens.airyDark.accent).opacity(0.22)
                                     : Color(nsColor: .controlBackgroundColor))
                )
            if !isUser { Spacer(minLength: 40) }
        }
    }

    // MARK: 动作

    private func select(_ agent: AgentRecord?) {
        selectedAgent = agent
        selectedSession = nil
        messages = []
        reloadSessions()
    }

    private func reloadSessions() {
        guard let agent = selectedAgent else { sessions = []; return }
        guard let adapter = adapter(for: agent.id) else {
            sessions = []
            note = L10n.text("该 agent 暂未接入会话读取")
            return
        }
        do {
            sessions = try adapter.listSessions(limit: 50)
            note = sessions.isEmpty ? L10n.text("没有会话") : nil
            if let first = sessions.first { select(first) }
        } catch {
            sessions = []
            note = L10n.text("读取失败")
        }
    }

    private func select(_ session: AgentSession) {
        selectedSession = session
        guard let adapter = adapter(for: session.agentID) else { messages = []; return }
        messages = (try? adapter.messages(in: session, limit: 80)) ?? []
    }
}
