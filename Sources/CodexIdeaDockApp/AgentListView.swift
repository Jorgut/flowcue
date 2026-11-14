import SwiftUI
#if SWIFT_PACKAGE
import CodexIdeaDockCore
#endif

/// 本机 agent 清单：只读展示，按「可对话 / 仅检测」分组。
struct AgentListView: View {
    @State private var records: [AgentRecord] = []
    @State private var scannedAt: Date?

    private var drivable: [AgentRecord] { records.filter { $0.capabilities.contains(.chat) } }
    private var detectOnly: [AgentRecord] { records.filter { !$0.capabilities.contains(.chat) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
            VStack(alignment: .leading, spacing: FlowCueMetrics.space16) {
                    if !drivable.isEmpty {
                        section(title: L10n.text("可对话"), records: drivable)
                    }
                    if !detectOnly.isEmpty {
                        section(title: L10n.text("仅检测"), records: detectOnly)
                    }
                    if records.isEmpty {
                        Text(L10n.text("没有检测到任何 agent"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, FlowCueMetrics.space24)
                    }
            }
            .padding(FlowCueMetrics.space16)
            Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { if records.isEmpty { rescan() } }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: FlowCueMetrics.space8) {
            Text(L10n.text("本机 Agent"))
                .font(.headline)
            Text("\(records.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            if let scannedAt {
                Text(scannedAt, format: .dateTime.hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button {
                rescan()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("重新扫描"))
        }
        .padding(.horizontal, FlowCueMetrics.space16)
        .padding(.vertical, FlowCueMetrics.space12)
    }

    private func section(title: String, records: [AgentRecord]) -> some View {
        VStack(alignment: .leading, spacing: FlowCueMetrics.space8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(records) { record in
                    row(record)
                    if record.id != records.last?.id {
                        Divider().padding(.leading, 22)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: FlowCueMetrics.radiusCard, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: FlowCueMetrics.radiusCard, style: .continuous)
                    .strokeBorder(Color(hex: FlowCueTokens.airyDark.border))
            )
        }
    }

    private func row(_ record: AgentRecord) -> some View {
        HStack(alignment: .center, spacing: FlowCueMetrics.space8) {
            Circle()
                .fill(record.capabilities.contains(.chat)
                      ? Color(hex: FlowCueTokens.airyDark.success)
                      : Color(hex: FlowCueTokens.airyDark.textTertiary))
                .frame(width: FlowCueMetrics.statusDot, height: FlowCueMetrics.statusDot)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(record.displayName).font(.callout)
                    if record.kind == .app {
                        Text(L10n.text("桌面端"))
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.quaternary))
                    }
                }
                Text(record.executablePath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            if let version = record.version {
                Text(version)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, FlowCueMetrics.space12)
        .padding(.vertical, FlowCueMetrics.space8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(record.displayName)，\(record.version ?? "")，\(record.executablePath)")
    }

    private func rescan() {
        records = AgentDiscovery.scan()
        scannedAt = Date()
    }
}
