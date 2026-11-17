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
    @State private var search = ""
    @State private var starredOnly = false
    @State private var crossAgentResults: [AgentSession] = []
    @State private var searchingAll = false
    @State private var reloadToken = 0
    @State private var upgradePrompt: String?

    private let service = AgentService.default

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
        .alert(L10n.text("需要 FlowCue Pro"), isPresented: Binding(
            get: { upgradePrompt != nil },
            set: { if !$0 { upgradePrompt = nil } }
        )) {
            Button(L10n.text("了解更多")) {
                if let url = URL(string: "https://altn.vision/flowcue/mac") { NSWorkspace.shared.open(url) }
                upgradePrompt = nil
            }
            Button(L10n.text("稍后"), role: .cancel) { upgradePrompt = nil }
        } message: {
            Text((upgradePrompt ?? "") + "\n" + L10n.text("在 iPhone 上订阅后，这台 Mac 会自动解锁。"))
        }
        .onAppear {
            if agents.isEmpty { agents = AgentDiscovery.scan() }
            if selectedAgent == nil { select(agents.first { $0.capabilities.contains(.session) }) }
        }
    }

    // MARK: 列

    private var agentColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(L10n.text("Agent")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(isPro ? "Pro" : "Free")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(isPro ? Color(hex: FlowCueTokens.airyDark.accent).opacity(0.25)
                                                     : Color(hex: FlowCueTokens.airyDark.border)))
                    .foregroundStyle(isPro ? Color(hex: FlowCueTokens.airyDark.accent) : .secondary)
            }
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
                Button { starredOnly.toggle() } label: {
                    Image(systemName: starredOnly ? "star.fill" : "star")
                        .font(.caption)
                        .foregroundStyle(starredOnly ? Color(hex: FlowCueTokens.airyDark.warning) : .secondary)
                }
                .buttonStyle(.plain)
                .help(L10n.text("只看收藏"))
                Button { Task { await reloadSessions() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).font(.caption)
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 6)

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 9)).foregroundStyle(.secondary)
                TextField("", text: $search, prompt: Text(L10n.text("搜索会话")))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .onSubmit { Task { await searchAllAgentsIfNeeded() } }
                if !search.isEmpty {
                    Button { search = ""; crossAgentResults = [] } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 12).padding(.bottom, 6)

            if let note {
                VStack(alignment: .leading, spacing: 6) {
                    Text(note).font(.caption2).foregroundStyle(.secondary)
                    if selectedAgent?.id == "dsh" {
                        Button(L10n.text("重新检查")) { Task { await reloadSessions() } }
                            .controlSize(.mini)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            ScrollView(.vertical) {
                LazyVStack(spacing: 2) {
                    ForEach(visibleSessions) { session in
                        Button { select(session) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    if AgentSessionArchive.isStarred(agentID: session.agentID, sessionID: session.id) {
                                        Image(systemName: "star.fill")
                                            .font(.system(size: 8))
                                            .foregroundStyle(Color(hex: FlowCueTokens.airyDark.warning))
                                    }
                                    Text(session.title).font(.callout).lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
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
                        .contextMenu {
                            Button(AgentSessionArchive.isStarred(agentID: session.agentID, sessionID: session.id)
                                   ? L10n.text("取消收藏") : L10n.text("收藏会话")) {
                                guard requirePro(L10n.text("收藏与搜索是 Pro 功能")) else { return }
                                _ = AgentSessionArchive.toggle(agentID: session.agentID, sessionID: session.id)
                                reloadToken &+= 1
                            }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    @State private var draft = ""
    @State private var sending = false
    @State private var sendNote: String?
    @State private var broadcasting = false
    @State private var broadcastResults: [(String, Bool)] = []
    @State private var showBroadcastResults = false

    private var messageColumn: some View {
        VStack(spacing: 0) {
            if let session = selectedSession {
                if !dispatchResults.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(dispatchResults) { result in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(result.ok ? Color(hex: FlowCueTokens.airyDark.success)
                                                    : Color(hex: FlowCueTokens.airyDark.warning))
                                    .frame(width: 5, height: 5)
                                Text(result.agent).font(.caption2)
                                Text(result.note).font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color(hex: FlowCueTokens.airyDark.surface))
                    Divider()
                }
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

                Divider()

                HStack(spacing: 8) {
                    TextField("", text: $draft, prompt: Text(L10n.text("发一条消息…")), axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...4)
                        .font(.callout)
                    if let sendNote {
                        Text(sendNote)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await broadcast() }
                    } label: {
                        Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 11))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .disabled(broadcasting || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(isPro ? 1 : 0.4)
                    .help(L10n.text("同时发给所有可对话 agent 的最近会话"))
                    .accessibilityLabel(L10n.text("并行分发"))

                    Button {
                        Task { await send(to: session) }
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.caption.weight(.semibold))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color(hex: FlowCueTokens.airyDark.accent)))
                            .foregroundStyle(Color(hex: "#0A0A12"))
                    }
                    .buttonStyle(.plain)
                    .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(isPro ? 1 : 0.4)
                    .accessibilityLabel(L10n.text("发送"))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
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

    private var visibleSessions: [AgentSession] {
        let base = search.isEmpty ? sessions : sessions.filter { matches($0) }
        let filtered = starredOnly
            ? base.filter { AgentSessionArchive.isStarred(agentID: $0.agentID, sessionID: $0.id) }
            : base
        if search.isEmpty { return filtered }
        // 搜索时把其它 agent 的结果接在后面
        let others = crossAgentResults.filter { result in
            result.agentID != selectedAgent?.id && matches(result)
                && (!starredOnly || AgentSessionArchive.isStarred(agentID: result.agentID, sessionID: result.id))
        }
        return filtered + others
    }

    private func matches(_ session: AgentSession) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return true }
        return session.title.lowercased().contains(query)
            || (session.projectPath ?? "").lowercased().contains(query)
    }

    private func searchAllAgentsIfNeeded() async {
        guard requirePro(L10n.text("收藏与搜索是 Pro 功能")) else { return }
        guard !search.isEmpty, !searchingAll else { return }
        searchingAll = true
        defer { searchingAll = false }
        let targets = agents.filter { $0.capabilities.contains(.chat) && $0.id != selectedAgent?.id }
        var collected: [AgentSession] = []
        await withTaskGroup(of: [AgentSession].self) { group in
            for agent in targets {
                group.addTask { (try? await service.sessions(for: agent.id, limit: 20)) ?? [] }
            }
            for await chunk in group { collected.append(contentsOf: chunk) }
        }
        crossAgentResults = collected
    }

    private func select(_ agent: AgentRecord?) {
        selectedAgent = agent
        selectedSession = nil
        messages = []
        Task { await reloadSessions() }
    }

    private func reloadSessions() async {
        guard let agent = selectedAgent else { sessions = []; return }
        guard service.adapter(for: agent.id) != nil else {
            sessions = []
            note = L10n.text("该 agent 暂未接入会话读取")
            return
        }
        do {
            let loaded = try await service.sessions(for: agent.id, limit: 50)
            sessions = loaded
            note = loaded.isEmpty ? L10n.text("没有会话") : nil
            if let first = loaded.first {
                selectedSession = first
                messages = (try? await service.messages(first, limit: 80)) ?? []
            }
        } catch {
            sessions = []
            if agent.id == "dsh" {
                note = L10n.text("桥接未连接，iPhone 上的审批暂时收不到。")
            } else {
                note = L10n.text("读取失败")
            }
        }
    }

    private struct DispatchResult: Identifiable {
        let id = UUID()
        let agent: String
        let ok: Bool
        let note: String
    }

    @State private var dispatchResults: [DispatchResult] = []

    private func broadcast() async {
        guard requirePro(L10n.text("并行分发是 Pro 功能")) else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !broadcasting else { return }
        broadcasting = true
        sendNote = nil
        dispatchResults = []

        let targets = agents.filter { $0.capabilities.contains(.chat) }
        var results: [DispatchResult] = []

        await withTaskGroup(of: DispatchResult.self) { group in
            for agent in targets {
                group.addTask {
                    do {
                        let sessions = try await service.sessions(for: agent.id, limit: 1)
                        guard let latest = sessions.first else {
                            return DispatchResult(agent: agent.displayName, ok: false, note: L10n.text("没有会话"))
                        }
                        try await service.send(text, to: latest)
                        return DispatchResult(agent: agent.displayName, ok: true, note: L10n.text("已送达"))
                    } catch {
                        return DispatchResult(agent: agent.displayName, ok: false, note: L10n.text("发送失败"))
                    }
                }
            }
            for await result in group {
                results.append(result)
            }
        }

        dispatchResults = results.sorted { $0.agent < $1.agent }
        broadcasting = false
        if results.allSatisfy({ $0.ok }) { draft = "" }
    }

    private var isPro: Bool { ProEntitlement.isPro() }

    /// 未解锁时给出升级提示并返回 false。
    private func requirePro(_ what: String) -> Bool {
        if isPro { return true }
        upgradePrompt = what
        return false
    }

    private func send(to session: AgentSession) async {
        guard requirePro(L10n.text("给 agent 发消息是 Pro 功能")) else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        sendNote = nil
        do {
            try await service.send(text, to: session)
            draft = ""
            sendNote = L10n.text("已送达")
            await reloadSessions()
            if let current = selectedSession {
                messages = (try? await service.messages(current, limit: 80)) ?? messages
            }
        } catch {
            sendNote = L10n.text("发送失败")
        }
        sending = false
    }

    private func select(_ session: AgentSession) {
        selectedSession = session
        Task { messages = (try? await service.messages(session, limit: 80)) ?? [] }
    }
}
