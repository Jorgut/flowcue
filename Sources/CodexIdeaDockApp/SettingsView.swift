import SwiftUI
#if SWIFT_PACKAGE
import CodexIdeaDockCore
#endif

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, panel, agents, integrations, remote, sync, usage, pro, updates, lab, feedback
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: L10n.text("通用")
        case .panel: L10n.text("面板")
        case .agents: L10n.text("Agent")
        case .integrations: L10n.text("集成")
        case .remote: L10n.text("远程")
        case .sync: L10n.text("同步")
        case .usage: L10n.text("用量")
        case .pro: L10n.text("Pro")
        case .updates: L10n.text("更新")
        case .lab: L10n.text("实验室")
        case .feedback: L10n.text("反馈")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .panel: "rectangle.on.rectangle"
        case .agents: "person.2"
        case .integrations: "puzzlepiece"
        case .remote: "iphone"
        case .sync: "icloud"
        case .usage: "chart.bar"
        case .pro: "star"
        case .updates: "arrow.down.circle"
        case .lab: "flask"
        case .feedback: "envelope"
        }
    }

    var isReady: Bool {
        switch self {
        case .general, .panel, .agents, .integrations, .remote, .sync, .usage, .pro, .updates, .lab, .feedback: true
        default: false
        }
    }
}

struct SettingsView: View {
    @State private var section: SettingsSection = SettingsView.initialSection

    static var initialSection: SettingsSection {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-settingsPage"), index + 1 < args.count,
           let value = SettingsSection(rawValue: args[index + 1]) {
            return value
        }
        return .general
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 190)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    content
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(SettingsSection.allCases) { item in
                        Button { section = item } label: {
                            HStack(spacing: 8) {
                                Image(systemName: item.symbol)
                                    .font(.system(size: 11))
                                    .frame(width: 16)
                                Text(item.title)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                if !item.isReady {
                                    Text(L10n.text("即将"))
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(section == item ? Color(hex: FlowCueTokens.airyDark.accent).opacity(0.18) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(section == item ? Color(hex: FlowCueTokens.airyDark.accent) : .primary)
                        .padding(.horizontal, 8)
                    }
                }
                .padding(.vertical, 10)
            }
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(hex: FlowCueTokens.airyDark.accent))
                Text("FlowCue")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Text(versionText)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(section.title)
                .font(.system(size: 17, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        switch section {
        case .general: L10n.text("语言、外观与收件箱布局")
        case .panel: L10n.text("快捷键、尺寸与关闭行为")
        case .remote: L10n.text("这台 Mac 的配对与远程会话")
        case .sync: L10n.text("iCloud 同步与本地存储")
        case .usage: L10n.text("Codex 额度与重置时间")
        case .pro: L10n.text("解锁全部主题、同步与远程续写")
        case .updates: L10n.text("版本与更新检查")
        case .lab: L10n.text("实验特性，默认关闭，可能随时改动或消失。")
        case .feedback: L10n.text("一般反馈 + 最近 20 行日志，从不包含想法内容。")
        case .agents: L10n.text("这台机器上能用的 coding agent")
        case .integrations: L10n.text("Codex、DSH、Claude Code 的连接状态")
        default: L10n.text("这个页面还在设计中")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .general: GeneralSettingsPage()
        case .panel: PanelSettingsPage()
        case .agents: AgentsSettingsPage()
        case .integrations: IntegrationsSettingsPage()
        case .remote: RemoteSettingsPage()
        case .sync: SyncSettingsPage()
        case .usage: UsageSettingsPage()
        case .pro: ProSettingsPage()
        case .updates: UpdatesSettingsPage()
        case .lab: LabSettingsPage()
        case .feedback: FeedbackSettingsPage()
        default: PlaceholderPage()
        }
    }
}

// MARK: - 通用

private struct GeneralSettingsPage: View {
    @AppStorage("FlowCue.inboxLayout") private var layoutRaw = "three"
    @AppStorage("FlowCue.showMenuBarIcon") private var showMenuBarIcon = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: L10n.text("外观与语言")) {
                SettingsRow(title: L10n.text("语言")) {
                    Picker("", selection: Binding(
                        get: { L10n.language },
                        set: { newValue in
                            UserDefaults.standard.set(newValue.rawValue, forKey: L10n.preferenceKey)
                        }
                    )) {
                        ForEach(AppLanguage.allCases, id: \.self) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .tint(Color(hex: FlowCueTokens.airyDark.accent))
                    .frame(width: 180)
                }
            }

            SettingsGroup(title: L10n.text("收件箱布局")) {
                SettingsRow(title: L10n.text("默认布局")) {
                    Picker("", selection: $layoutRaw) {
                        Text(L10n.text("三栏")).tag("three")
                        Text(L10n.text("底部输入")).tag("bottom")
                        Text(L10n.text("侧栏")).tag("sidebar")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .tint(Color(hex: FlowCueTokens.airyDark.accent))
                    .frame(width: 300)
                }
                Text(L10n.text("切换后立即生效，收件箱右上角的图标也会同步。"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            SettingsGroup(title: L10n.text("菜单栏")) {
                SettingsRow(title: L10n.text("显示菜单栏图标")) {
                    Toggle("", isOn: $showMenuBarIcon).labelsHidden().toggleStyle(.switch)
                        .tint(Color(hex: FlowCueTokens.airyDark.accent))
                }
            }
        }
    }
}

// MARK: - Agent

private struct AgentsSettingsPage: View {
    @State private var records: [AgentRecord] = []

    private var drivable: [AgentRecord] { records.filter { $0.capabilities.contains(.chat) } }
    private var detectOnly: [AgentRecord] { records.filter { !$0.capabilities.contains(.chat) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: L10n.text("可对话"), footnote: L10n.text("能读会话、能发消息")) {
                ForEach(drivable) { record in
                    AgentRow(record: record, drivable: true)
                }
                if drivable.isEmpty {
                    Text(L10n.text("没有可对话的 agent")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            SettingsGroup(title: L10n.text("仅检测"), footnote: L10n.text("只列出是否安装，不接管")) {
                ForEach(detectOnly) { record in
                    AgentRow(record: record, drivable: false)
                }
            }
            Button(L10n.text("重新扫描")) { records = AgentDiscovery.scan() }
                .controlSize(.small)
        }
        .onAppear { if records.isEmpty { records = AgentDiscovery.scan() } }
    }
}

private struct AgentRow: View {
    let record: AgentRecord
    let drivable: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(drivable ? Color(hex: FlowCueTokens.airyDark.success)
                               : Color(hex: FlowCueTokens.airyDark.textTertiary))
                .frame(width: 6, height: 6)
            Text(record.displayName).font(.system(size: 12))
            if record.kind == .app {
                Text(L10n.text("桌面端"))
                    .font(.system(size: 9))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary))
            }
            Spacer()
            Text(record.version ?? record.executablePath)
                .font(.system(size: 10).monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - 集成

private struct IntegrationsSettingsPage: View {
    @State private var records: [AgentRecord] = []
    @State private var dshConfigured = false
    @State private var bridgeReachable = false
    @State private var portOccupied = false
    @State private var hooksInstalled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: "Codex") {
                status(records.first { $0.id == "codex" }, ping: L10n.text("app-server 可用"))
            }
            SettingsGroup(title: "DSH") {
                SettingsRow(title: L10n.text("本机桥")) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(bridgeReachable ? Color(hex: FlowCueTokens.airyDark.success)
                                                  : Color(hex: FlowCueTokens.airyDark.warning))
                            .frame(width: 6, height: 6)
                        Text(bridgeReachable ? L10n.text("已连接")
                                             : (dshConfigured ? L10n.text("未连接") : L10n.text("未安装")))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                SettingsRow(title: L10n.text("端口")) {
                    HStack(spacing: 6) {
                        Text("127.0.0.1:47823").font(.system(size: 11).monospaced())
                        if portOccupied && !bridgeReachable {
                            Text(L10n.text("被占用"))
                                .font(.system(size: 9))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color(hex: FlowCueTokens.airyDark.warning).opacity(0.2)))
                                .foregroundStyle(Color(hex: FlowCueTokens.airyDark.warning))
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                if !bridgeReachable {
                    Text(dshConfigured
                         ? L10n.text("桥已配置但没有响应，重启 DSH 后再试。")
                         : L10n.text("安装 DSH 桥后，iPhone 上的审批才能回到这里。"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                if portOccupied && !bridgeReachable {
                    Text(L10n.text("端口被别的进程占用；关掉它或到 DSH 里改用其他端口。"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Button(L10n.text("重新检查")) { checkBridge() }
                    .controlSize(.small)
            }
            SettingsGroup(title: "Codex hooks") {
                SettingsRow(title: L10n.text("hooks")) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(hooksInstalled ? Color(hex: FlowCueTokens.airyDark.success)
                                                 : Color(hex: FlowCueTokens.airyDark.textTertiary))
                            .frame(width: 6, height: 6)
                        Text(hooksInstalled ? L10n.text("已安装") : L10n.text("未安装"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                if !hooksInstalled {
                    Text(L10n.text("装好 hooks 后，Codex 跑完才会回来通知这条想法。"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Button(L10n.text("查看安装指引")) {
                        if let url = URL(string: "https://github.com/Jorgut/flowcue#hooks") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
            }

            SettingsGroup(title: "Claude Code") {
                status(records.first { $0.id == "claude" }, ping: L10n.text("读取 ~/.claude/projects"))
            }
        }
        .onAppear {
            if records.isEmpty { records = AgentDiscovery.scan() }
            checkBridge()
        }
    }

    private func checkBridge() {
        dshConfigured = DSHBridgeClient().isConfigured
        bridgeReachable = PortProbe.isOpen(port: 47823)
        portOccupied = PortProbe.isOccupied(port: 47823)
        hooksInstalled = CodexHooks.isInstalled
    }

    @ViewBuilder
    private func status(_ record: AgentRecord?, ping: String) -> some View {
        if let record {
            HStack(spacing: 8) {
                Circle().fill(Color(hex: FlowCueTokens.airyDark.success)).frame(width: 6, height: 6)
                Text(record.version ?? "-")
                    .font(.system(size: 11).monospaced())
                Spacer()
                Text(ping).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text(record.executablePath)
                .font(.system(size: 10).monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            Text(L10n.text("未安装")).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

private struct PanelSettingsPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: L10n.text("快捷键")) {
                SettingsRow(title: L10n.text("唤起面板")) {
                    Text("⌃⌥Space").font(.system(size: 11).monospaced())
                }
                SettingsRow(title: L10n.text("保存")) {
                    Text("⌘ ↩").font(.system(size: 11).monospaced())
                }
                SettingsRow(title: L10n.text("排队")) {
                    Text("⌘ ⇧ ↩").font(.system(size: 11).monospaced())
                }
            }
            SettingsGroup(title: L10n.text("尺寸"), footnote: L10n.text("固定尺寸，保证写作区域稳定。")) {
                SettingsRow(title: L10n.text("面板")) {
                    Text("520 × 280").font(.system(size: 11).monospaced())
                }
            }
            SettingsGroup(title: L10n.text("行为"), footnote: L10n.text("这些行为当前固定，后续在实验室里开放。")) {
                SettingsRow(title: L10n.text("失去焦点自动收起")) { Text(L10n.text("开")).font(.system(size: 11)).foregroundStyle(.secondary) }
                SettingsRow(title: L10n.text("保存后收起")) { Text(L10n.text("开")).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
        }
    }
}

private struct RemoteSettingsPage: View {
    @AppStorage("FlowCue.remoteContinuationEnabled") private var enabled = false
    @State private var code: String = UserDefaults.standard.string(forKey: "FlowCue.remotePairingCode") ?? "------"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: L10n.text("这台 Mac")) {
                SettingsRow(title: L10n.text("允许远程会话")) {
                    Toggle("", isOn: $enabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(Color(hex: FlowCueTokens.airyDark.accent))
                }
                SettingsRow(title: L10n.text("配对码")) {
                    HStack(spacing: 8) {
                        Text(code).font(.system(size: 12).monospaced())
                        Button(L10n.text("重新生成")) {
                            let new = String(format: "%06d", Int.random(in: 0...999_999))
                            UserDefaults.standard.set(new, forKey: "FlowCue.remotePairingCode")
                            code = new
                        }
                        .controlSize(.small)
                    }
                }
            }
            Text(L10n.text("重新生成后，已配对的设备需要重新输入。"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            SettingsGroup(title: L10n.text("已配对设备")) {
                HStack(spacing: 8) {
                    Circle().fill(Color(hex: FlowCueTokens.airyDark.textTertiary)).frame(width: 6, height: 6)
                    Text(L10n.text("暂无设备")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(minHeight: 30)
            }
        }
    }
}

private struct SyncSettingsPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: L10n.text("iCloud")) {
                SettingsRow(title: L10n.text("同步想法与会话")) {
                    Text(L10n.text("随本机设置")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            SettingsGroup(title: L10n.text("存储")) {
                SettingsRow(title: L10n.text("本机数据库")) {
                    Text(localSize).font(.system(size: 11).monospaced()).foregroundStyle(.secondary)
                }
            }
            Text(L10n.text("iCloud 同步的开关在菜单栏里，这一页只做只读展示。"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var localSize: String {
        let url = URL.applicationSupportDirectory
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

private struct UsageSettingsPage: View {
    @State private var usage: CodexUsageSnapshot?
    @State private var loading = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: L10n.text("额度")) {
                if let usage {
                    HStack(spacing: 28) {
                        ForEach(Array([usage.primary, usage.secondary].compactMap { $0 }.enumerated()), id: \.offset) { _, window in
                            FlowCueUsageRing(
                                progress: window.usedPercent / 100,
                                caption: title(for: window),
                                valueText: "\(Int(window.usedPercent))% " + L10n.text("已用")
                            )
                        }
                        Spacer()
                        Button(L10n.text("打开 Codex")) {
                            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
                                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                            }
                        }
                        .controlSize(.small)
                    }
                    .frame(minHeight: 40)

                    if let resets = usage.primary?.resetsAt {
                        SettingsRow(title: L10n.text("下次重置")) {
                            Text(Date(timeIntervalSince1970: resets), format: .dateTime.month().day().hour().minute())
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text(loading ? L10n.text("正在读取用量…")
                                 : (failed ? L10n.text("用量暂不可用") : L10n.text("正在读取用量…")))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 40)
                }
            }

            Button(L10n.text("刷新")) { Task { await load() } }
                .controlSize(.small)
        }
        .task { await load() }
    }

    private func title(for window: CodexUsageWindow) -> String {
        let minutes = window.windowDurationMins ?? 0
        if minutes >= 10000 { return L10n.text("每周") }
        if minutes >= 60 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    private func load() async {
        loading = true; failed = false
        do {
            usage = try await CodexBridge().readUsage()
        } catch {
            failed = true
        }
        loading = false
    }
}

private struct ProSettingsPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: L10n.text("Pro")) {
                ForEach(Array([
                    L10n.text("全部 13 套主题"),
                    L10n.text("iCloud 同步"),
                    L10n.text("iPhone 远程续写"),
                    L10n.text("优先支持")
                ].enumerated()), id: \.offset) { _, line in
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color(hex: FlowCueTokens.airyDark.accent))
                        Text(line).font(.system(size: 12))
                        Spacer()
                    }
                    .frame(minHeight: 26)
                }
            }
            HStack(spacing: 10) {
                Button(L10n.text("了解更多")) {
                    if let url = URL(string: "https://flowcue.app/pro") { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Color(hex: FlowCueTokens.airyDark.accent))
                Text(L10n.text("订阅在 App Store 完成，桌面端不使用独立付费。"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct UpdatesSettingsPage: View {
    @State private var checking = false
    @State private var latest: String?
    @State private var failed = false

    private var current: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: L10n.text("版本")) {
                SettingsRow(title: L10n.text("当前版本")) {
                    Text(current).font(.system(size: 11).monospaced()).foregroundStyle(.secondary)
                }
                SettingsRow(title: L10n.text("最新版本")) {
                    Text(latest ?? (checking ? L10n.text("检查中…") : (failed ? L10n.text("检查失败") : L10n.text("未检查"))))
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                Button(L10n.text("检查更新")) { Task { await check() } }
                    .controlSize(.small)
                    .disabled(checking)
                Text(L10n.text("更新通过 App Store 或 TestFlight 分发。"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func check() async {
        checking = true; failed = false
        defer { checking = false }
        guard let url = URL(string: "https://api.github.com/repos/Jorgut/flowcue/releases/latest") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("FlowCue", forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            struct Release: Decodable { let tag_name: String }
            latest = try JSONDecoder().decode(Release.self, from: data).tag_name
        } catch {
            failed = true
        }
    }
}

private struct LabSettingsPage: View {
    @AppStorage("FlowCue.lab.voice") private var voice = false
    @AppStorage("FlowCue.lab.grouping") private var grouping = false
    @AppStorage("FlowCue.lab.multiAgent") private var multiAgent = false
    @AppStorage("FlowCue.lab.notchHUD") private var notchHUD = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: L10n.text("正在实验"),
                          footnote: L10n.text("这里的开关会随版本变化，关掉即回到稳定行为。")) {
                labRow(L10n.text("语音边录边转写"), L10n.text("按住说话，松开即插入，不走后台。"), $voice)
                labRow(L10n.text("智能归类"), L10n.text("按来源和内容自动分组。"), $grouping)
                labRow(L10n.text("多 agent 并行"), L10n.text("同一想法可以同时交给多个 agent。"), $multiAgent)
                labRow(L10n.text("刘海 HUD · 试用版"), L10n.text("在刘海两侧显示状态，不占屏幕。"), $notchHUD)
            }
        }
    }

    private func labRow(_ title: String, _ detail: String, _ binding: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: binding)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Color(hex: FlowCueTokens.airyDark.accent))
        }
        .frame(minHeight: 38)
    }
}

private struct FeedbackSettingsPage: View {
    @AppStorage("FlowCue.feedback.attachLogs") private var attachLogs = true
    @State private var kind = 0
    @State private var text = ""
    @State private var sent = false

    private var isSendable: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var payload: String {
        let types = [L10n.text("问题"), L10n.text("建议"), L10n.text("其他")]
        var body = "\(types[kind])\n\n\(text)"
        if attachLogs {
            body += "\n\n---\nFlowCue \(version) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        }
        return body
    }

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: L10n.text("告诉我们哪里不对")) {
                Picker("", selection: $kind) {
                    Text(L10n.text("问题")).tag(0)
                    Text(L10n.text("建议")).tag(1)
                    Text(L10n.text("其他")).tag(2)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .tint(Color(hex: FlowCueTokens.airyDark.accent))
                .frame(width: 240)
                .padding(.vertical, 4)

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .font(.system(size: 12))
                        .scrollContentBackground(.hidden)
                        .frame(height: 120)
                    if text.isEmpty {
                        Text(L10n.text("描述一下发生了什么…"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.35),
                            in: RoundedRectangle(cornerRadius: FlowCueMetrics.radiusInline, style: .continuous))

                SettingsRow(title: L10n.text("附带诊断日志")) {
                    Toggle("", isOn: $attachLogs)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(Color(hex: FlowCueTokens.airyDark.accent))
                }
                Text(L10n.text("只含版本号和最近 20 行日志，不含想法正文。"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button(L10n.text("复制反馈")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(payload, forType: .string)
                    sent = true
                }
                .controlSize(.small)

                Button(L10n.text("发送")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(payload, forType: .string)
                    if let url = URL(string: "mailto:hello@flowcue.app?subject=FlowCue%20Feedback&body=\(payload.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") {
                        NSWorkspace.shared.open(url)
                    }
                    sent = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Color(hex: FlowCueTokens.airyDark.accent))
                .disabled(!isSendable)

                if sent {
                    Text(L10n.text("已复制，可在邮件里粘贴"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct PlaceholderPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("这一页还在设计中"))
                .font(.system(size: 13))
            Text(L10n.text("设计稿已完成，等前面的页面稳定后再实现。"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 20)
    }
}

// MARK: - 基础件

private struct SettingsGroup<Content: View>: View {
    let title: String
    var footnote: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: FlowCueMetrics.radiusCard, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: FlowCueMetrics.radiusCard, style: .continuous)
                    .strokeBorder(Color(hex: FlowCueTokens.airyDark.border))
            }
            if let footnote {
                Text(footnote).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SettingsRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 12))
                Spacer(minLength: 12)
                content()
            }
            .frame(minHeight: 30)
            Divider().opacity(0.5)
        }
    }
}
