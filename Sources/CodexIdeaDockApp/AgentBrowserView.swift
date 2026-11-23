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

    @State private var approvals: [DSHRemoteApproval] = []

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                sessionsColumn
                    .frame(width: 250)
                    .clipped()
                Divider()
                messageColumn
                    .frame(width: max(320, geo.size.width - 492), height: geo.size.height)
                    .clipped()
                Divider()
                inspectorColumn
                    .frame(width: 240)
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
            if sessions.isEmpty { Task { await loadAllSessions() } }
            Task { await refreshApprovals() }
        }
    }

    // MARK: 列

    private var sessionsColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Circle()
                    .fill(Color(hex: FlowCueTokens.airyDark.success))
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.text("本机 Mac")).font(.system(size: 12.5, weight: .semibold))
                    Text(bridgeOnline ? L10n.text("在线") : L10n.text("DSH 未连接"))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 9)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.tertiary)
                TextField("", text: $search, prompt: Text(L10n.text("搜索会话")).font(.system(size: 11.5)))
                    .textFieldStyle(.plain).font(.system(size: 11.5))
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
            .padding(.horizontal, 10)

            HStack(spacing: 10) {
                filterTab(nil, title: L10n.text("全部"))
                ForEach(agents.filter { $0.capabilities.contains(.session) }) { agent in
                    filterTab(agent.id, title: agent.displayName)
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 9)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(visibleSessions) { session in
                        sessionRow(session)
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 8)
            }

            if let note {
                Text(note).font(.system(size: 10)).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
        }
    }

    private func filterTab(_ agentID: String?, title: String) -> some View {
        let isOn = selectedAgent?.id == agentID
        return Button {
            select(agentID.flatMap { id in agents.first { $0.id == id } })
        } label: {
            Text(title)
                .font(.system(size: 11, weight: isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? Color(hex: FlowCueTokens.airyDark.accent) : .secondary)
        }
        .buttonStyle(.plain)
    }

    private func sessionRow(_ session: AgentSession) -> some View {
        Button {
            selectedSession = session
            Task {
                messages = (try? await service.messages(session, limit: 80)) ?? []
                await refreshApprovals()
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(hex: FlowCueTokens.airyDark.success).opacity(session.agentID == "dsh" ? 0.55 : 1))
                        .frame(width: 5, height: 5)
                    Text(session.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(session.updatedAt, format: .relative(presentation: .named))
                        .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                }
                Text(metaLine(session))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: FlowCueMetrics.radiusInline, style: .continuous)
                    .fill(selectedSession?.id == session.id
                          ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.18)
                          : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func metaLine(_ session: AgentSession) -> String {
        let name = agents.first { $0.id == session.agentID }?.displayName ?? session.agentID
        let project = session.projectPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        return project.isEmpty ? name : "\(name) · \(project)"
    }

    private var inspectorColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                inspectorGroup(L10n.text("会话")) {
                    if let session = selectedSession {
                        inspectorKV(L10n.text("Agent"), agents.first { $0.id == session.agentID }?.displayName ?? session.agentID)
                        inspectorKV(L10n.text("节点"), L10n.text("本机 Mac"))
                        inspectorKV(L10n.text("工作区"), session.projectPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "—")
                        inspectorKV(L10n.text("状态"), L10n.text("可读取"))
                    } else {
                        Text(L10n.text("未选择会话")).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }

                inspectorGroup(L10n.text("这台机器上的 Agents")) {
                    ForEach(agents.filter { $0.capabilities.contains(.session) }) { agent in
                        HStack(spacing: 7) {
                            Text(String(agent.displayName.prefix(1)))
                                .font(.system(size: 9.5, weight: .semibold))
                                .frame(width: 18, height: 18)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .controlBackgroundColor)))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(agent.displayName).font(.system(size: 10.5))
                                Text(sessions.filter { $0.agentID == agent.id }.count.description + " " + L10n.text("个会话"))
                                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Circle().fill(Color(hex: FlowCueTokens.airyDark.textTertiary)).frame(width: 5, height: 5)
                        }
                    }
                }

                inspectorGroup(L10n.text("节点")) {
                    inspectorKV(L10n.text("系统"), ProcessInfo.processInfo.operatingSystemVersionString)
                    inspectorKV(L10n.text("版本"), appVersion)
                    inspectorKV(L10n.text("协议"), "v1")
                }

                inspectorGroup(L10n.text("审批")) {
                    inspectorKV(L10n.text("待审批"), "\(approvals.count)")
                    inspectorKV(L10n.text("桥接"), bridgeOnline ? L10n.text("已连接") : L10n.text("未连接"))
                }
            }
            .padding(14)
        }
    }

    private func inspectorGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 9.5)).foregroundStyle(.tertiary)
            content()
        }
    }

    private func inspectorKV(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).font(.system(size: 10.5)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(.system(size: 10.5)).foregroundStyle(.secondary.opacity(0.9)).lineLimit(1)
        }
    }

    private var bridgeOnline: Bool { PortProbe.isOpen(port: 47823) }

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "—"
    }

    private func refreshApprovals() async {
        approvals = (try? await DSHBridgeClient().pending()) ?? []
    }

    private func loadAllSessions() async {
        var collected: [AgentSession] = []
        await withTaskGroup(of: [AgentSession].self) { group in
            for agent in agents where agent.capabilities.contains(.session) {
                group.addTask { (try? await service.sessions(for: agent.id, limit: 30)) ?? [] }
            }
            for await chunk in group { collected.append(contentsOf: chunk) }
        }
        sessions = collected.sorted { $0.updatedAt > $1.updatedAt }
        note = sessions.isEmpty ? L10n.text("没有会话") : nil
        if let first = sessions.first {
            selectedSession = first
            messages = (try? await service.messages(first, limit: 80)) ?? []
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(metaLine(session)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 9)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if messages.isEmpty {
                            Text(session.agentID == "dsh"
                                 ? L10n.text("在 DSH 里继续这个会话，这里可以发送消息。")
                                 : L10n.text("没有可读取的消息"))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 24)
                        }
                        ForEach(messages) { message in bubble(message) }
                    }
                    .padding(14)
                }

                if let approval = approvals.first(where: { $0.sessionId == session.id }) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.text("需要审批")).font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color(hex: FlowCueTokens.airyDark.warning))
                        Text(approval.title).font(.system(size: 12, weight: .semibold))
                        if let tool = approval.toolName {
                            Text(tool).font(.system(size: 10.5).monospaced()).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 8) {
                            Button(L10n.text("允许一次")) {
                                Task {
                                    try? await DSHBridgeClient().decide(id: approval.id, decision: "allowed-once")
                                    await refreshApprovals()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            Button(L10n.text("拒绝"), role: .destructive) {
                                Task {
                                    try? await DSHBridgeClient().decide(id: approval.id, decision: "rejected")
                                    await refreshApprovals()
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: FlowCueMetrics.radiusInline, style: .continuous)
                            .fill(Color(hex: FlowCueTokens.airyDark.warning).opacity(0.08))
                    )
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Color(hex: FlowCueTokens.airyDark.warning).opacity(0.55)).frame(width: 2)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
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
        if search.isEmpty || selectedAgent == nil { return filtered }
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
        Task {
            if agent == nil { await loadAllSessions() } else { await reloadSessions() }
        }
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
