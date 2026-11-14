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
        case .general, .agents, .integrations: true
        default: false
        }
    }
}

struct SettingsView: View {
    @State private var section: SettingsSection = .general

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
        case .agents: L10n.text("这台机器上能用的 coding agent")
        case .integrations: L10n.text("Codex、DSH、Claude Code 的连接状态")
        default: L10n.text("这个页面还在设计中")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .general: GeneralSettingsPage()
        case .agents: AgentsSettingsPage()
        case .integrations: IntegrationsSettingsPage()
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
                    .frame(width: 240)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: "Codex") {
                status(records.first { $0.id == "codex" }, ping: L10n.text("app-server 可用"))
            }
            SettingsGroup(title: "DSH") {
                SettingsRow(title: L10n.text("本机桥")) {
                    Text(dshConfigured ? L10n.text("已配置") : L10n.text("未安装"))
                        .font(.system(size: 11))
                        .foregroundStyle(dshConfigured ? Color(hex: FlowCueTokens.airyDark.success) : .secondary)
                }
                Text("~/.flowcue/dsh-bridge.json")
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(.secondary)
            }
            SettingsGroup(title: "Claude Code") {
                status(records.first { $0.id == "claude" }, ping: L10n.text("读取 ~/.claude/projects"))
            }
        }
        .onAppear {
            if records.isEmpty { records = AgentDiscovery.scan() }
            dshConfigured = DSHBridgeClient().isConfigured
        }
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
            VStack(alignment: .leading, spacing: 6) {
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
        HStack {
            Text(title).font(.system(size: 12))
            Spacer(minLength: 12)
            content()
        }
        .frame(minHeight: 22)
    }
}
