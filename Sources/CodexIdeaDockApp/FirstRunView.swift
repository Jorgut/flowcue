import SwiftUI
import UserNotifications
#if SWIFT_PACKAGE
import CodexIdeaDockCore
#endif

/// 三步首启：欢迎 → 配对 iPhone → 选默认 agent。
struct FirstRunView: View {
    let onFinish: () -> Void

    @State private var step: Int = {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-firstrunStep"), index + 1 < args.count,
           let value = Int(args[index + 1]) { return max(0, min(2, value)) }
        return 0
    }()
    @State private var agents: [AgentRecord] = []
    @State private var selectedAgentID: String?
    @AppStorage("FlowCue.defaultAgentID") private var storedAgentID = "codex"

    private let totalSteps = 3

    private var pairingCode: String {
        UserDefaults.standard.string(forKey: "FlowCue.remotePairingCode") ?? "------"
    }

    private var drivable: [AgentRecord] {
        agents.filter { $0.capabilities.contains(.chat) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(28)
            footer
        }
        .frame(width: 880, height: 430)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if agents.isEmpty { agents = AgentDiscovery.scan() }
            if selectedAgentID == nil { selectedAgentID = drivable.first?.id }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: welcome
        case 1: pairing
        default: agentChoice
        }
    }

    // MARK: 步骤

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color(hex: FlowCueTokens.airyDark.success).opacity(0.25))
                        .frame(width: 44, height: 44)
                    Circle().fill(Color(hex: FlowCueTokens.airyDark.success))
                        .frame(width: 22, height: 22)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("FlowCue 住在菜单栏"))
                        .font(.system(size: 20, weight: .semibold))
                    Text(L10n.text("随手记一句，投给你的 coding agent。"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 0) {
                FirstRunRow(title: L10n.text("全局快捷键")) {
                    Text("⌃⌥Space").font(.system(size: 11).monospaced()).foregroundStyle(.secondary)
                }
                FirstRunRow(title: L10n.text("允许通知")) {
                    Button(L10n.text("允许")) {
                        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                    }
                    .controlSize(.small)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: FlowCueMetrics.radiusCard, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: FlowCueMetrics.radiusCard, style: .continuous)
                    .strokeBorder(Color(hex: FlowCueTokens.airyDark.border))
            }
        }
    }

    private var pairing: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("连接你的 iPhone"))
                    .font(.system(size: 20, weight: .semibold))
                Text(L10n.text("在 iPhone 上打开 FlowCue → 配对，输入这串码。"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                ForEach(Array(pairingCode.enumerated()), id: \.offset) { _, character in
                    Text(String(character))
                        .font(.system(size: 20, weight: .semibold).monospacedDigit())
                        .frame(width: 44, height: 52)
                        .background(Color(nsColor: .controlBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color(hex: FlowCueTokens.airyDark.border))
                        }
                }
            }
            Text(L10n.text("配对码也可以只在本机局域网使用。"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var agentChoice: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("默认投给谁？"))
                    .font(.system(size: 20, weight: .semibold))
                Text(L10n.text("之后每条想法排队时，默认送到这里。"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if drivable.isEmpty {
                Text(L10n.text("没有检测到可用的 agent。安装 Codex CLI 或 Claude Code 后再回来。"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(drivable) { record in
                        Button {
                            selectedAgentID = record.id
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 7))
                                    .foregroundStyle(selectedAgentID == record.id
                                                     ? Color(hex: FlowCueTokens.airyDark.accent) : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(record.displayName).font(.system(size: 12))
                                    Text(record.version ?? record.executablePath)
                                        .font(.system(size: 9).monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedAgentID == record.id {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(Color(hex: FlowCueTokens.airyDark.accent))
                                }
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().opacity(0.4)
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: FlowCueMetrics.radiusCard, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: FlowCueMetrics.radiusCard, style: .continuous)
                        .strokeBorder(Color(hex: FlowCueTokens.airyDark.border))
                }
            }
        }
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                ForEach(0..<totalSteps, id: \.self) { index in
                    Circle()
                        .fill(index == step ? Color(hex: FlowCueTokens.airyDark.accent)
                                            : Color(hex: FlowCueTokens.airyDark.textTertiary).opacity(0.5))
                        .frame(width: 5, height: 5)
                }
            }
            Spacer()

            if step == 1 {
                Button(L10n.text("稍后")) { advance() }
                    .controlSize(.small)
                Button(L10n.text("已连接")) { advance() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(Color(hex: FlowCueTokens.airyDark.accent))
            } else if step == totalSteps - 1 {
                Button(L10n.text("开始使用")) { finish() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(Color(hex: FlowCueTokens.airyDark.accent))
            } else {
                Button(L10n.text("继续")) { advance() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(Color(hex: FlowCueTokens.airyDark.accent))
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }

    private func advance() {
        if step < totalSteps - 1 { step += 1 } else { finish() }
    }

    private func finish() {
        if let selectedAgentID { storedAgentID = selectedAgentID }
        UserDefaults.standard.set(true, forKey: "FlowCue.firstRunCompleted")
        onFinish()
    }
}

private struct FirstRunRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 12))
                Spacer()
                content()
            }
            .frame(height: 38)
            .padding(.horizontal, 12)
            Divider().opacity(0.4)
        }
    }
}
