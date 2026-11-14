#if canImport(SwiftUI)
import SwiftUI

// MARK: - 组件层
// 双端共用的最小 UI 组件：只吃 token，不含业务逻辑。
// 视图里直接用这些，不再各自拼一遍圆角/间距/状态色。

public enum FlowCueStatus: Sendable {
    case ok, waiting, failed

    public var token: String {
        switch self {
        case .ok: FlowCueTokens.airyDark.success
        case .waiting: FlowCueTokens.airyDark.warning
        case .failed: FlowCueTokens.airyDark.failure
        }
    }
}

public extension Color {
    init(flowCueHex hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255,
                  opacity: 1)
    }
}

/// 状态点：颜色 + 可选文字。永远不单靠颜色表达状态。
public struct FlowCueStatusDot: View {
    let status: FlowCueStatus
    var label: String? = nil
    var showsLabel: Bool = true

    public init(status: FlowCueStatus, label: String? = nil, showsLabel: Bool = true) {
        self.status = status
        self.label = label
        self.showsLabel = showsLabel
    }

    public var body: some View {
        HStack(spacing: FlowCueMetrics.space4) {
            Circle()
                .fill(Color(flowCueHex: status.token))
                .frame(width: FlowCueMetrics.statusDot, height: FlowCueMetrics.statusDot)
                .accessibilityHidden(true)
            if showsLabel, let label {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label ?? "")
    }
}

/// 胶囊筛选/标签。
public struct FlowCueChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    public init(_ title: String, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, FlowCueMetrics.space12)
                .frame(height: FlowCueMetrics.chipHeight)
                .background(
                    Capsule().fill(isSelected ? Color(flowCueHex: FlowCueTokens.airyDark.accent).opacity(0.16)
                                              : Color.clear)
                )
                .overlay(
                    Capsule().strokeBorder(
                        isSelected ? Color(flowCueHex: FlowCueTokens.airyDark.accent).opacity(0.55)
                                   : Color(flowCueHex: FlowCueTokens.airyDark.border)
                    )
                )
                .foregroundStyle(isSelected ? Color(flowCueHex: FlowCueTokens.airyDark.accent) : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// 列表行：标题 + 元信息 + 状态点 + 尾部。
public struct FlowCueListRow<Trailing: View>: View {
    let title: String
    let meta: String
    let status: FlowCueStatus
    let isSelected: Bool
    @ViewBuilder var trailing: () -> Trailing

    public init(title: String,
                meta: String,
                status: FlowCueStatus,
                isSelected: Bool = false,
                @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.meta = meta
        self.status = status
        self.isSelected = isSelected
        self.trailing = trailing
    }

    public var body: some View {
        HStack(alignment: .top, spacing: FlowCueMetrics.space8) {
            Circle()
                .fill(Color(flowCueHex: status.token))
                .frame(width: FlowCueMetrics.statusDot, height: FlowCueMetrics.statusDot)
                .padding(.top, 5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text(meta)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)，\(meta)")
    }
}

/// 输入条：左图标 + 文本 + 右主操作。
public struct FlowCueComposer<Leading: View>: View {
    @Binding var text: String
    let placeholder: String
    let actionSymbol: String
    let onSubmit: () -> Void
    @ViewBuilder var leading: () -> Leading

    public init(text: Binding<String>,
                placeholder: String,
                actionSymbol: String = "arrow.up",
                onSubmit: @escaping () -> Void,
                @ViewBuilder leading: @escaping () -> Leading = { EmptyView() }) {
        self._text = text
        self.placeholder = placeholder
        self.actionSymbol = actionSymbol
        self.onSubmit = onSubmit
        self.leading = leading
    }

    public var body: some View {
        HStack(spacing: FlowCueMetrics.space8) {
            leading()
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .font(.callout)
            Button(action: onSubmit) {
                Image(systemName: actionSymbol)
                    .font(.caption.weight(.semibold))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color(flowCueHex: FlowCueTokens.airyDark.accent)))
                    .foregroundStyle(Color(flowCueHex: "#0A0A12"))
            }
            .buttonStyle(.plain)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(placeholder)
        }
        .padding(.horizontal, FlowCueMetrics.space12)
        .padding(.vertical, FlowCueMetrics.space8)
        .background(
            RoundedRectangle(cornerRadius: FlowCueMetrics.radiusInline, style: .continuous)
                .fill(Color(flowCueHex: FlowCueTokens.airyDark.surface))
                .overlay(
                    RoundedRectangle(cornerRadius: FlowCueMetrics.radiusInline, style: .continuous)
                        .strokeBorder(Color(flowCueHex: FlowCueTokens.airyDark.border))
                )
        )
    }
}
#endif

#if canImport(SwiftUI)
/// 用量圆环：用于展示 Codex 的 5h / 每周额度。
public struct FlowCueUsageRing: View {
    let progress: Double      // 0...1
    let caption: String
    let valueText: String

    public init(progress: Double, caption: String, valueText: String) {
        self.progress = max(0, min(1, progress))
        self.caption = caption
        self.valueText = valueText
    }

    public var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color(flowCueHex: FlowCueTokens.airyDark.border), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color(flowCueHex: FlowCueTokens.airyDark.accent),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(caption)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text(valueText)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(caption) \(valueText)")
    }
}
#endif
