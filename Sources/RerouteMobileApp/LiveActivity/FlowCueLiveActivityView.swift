import SwiftUI

struct FlowCueLiveActivityLockScreenView: View {
    let attributes: FlowCueActivityAttributes
    let state: FlowCueActivityAttributes.ContentState

    private var palette: LiveActivityPalette { LiveActivityPalette(spec: FlowCueThemeSharing.currentSpec()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Text("FLOWCUE · \(attributes.agent.uppercased())")
                    .font(.system(size: 9, weight: .semibold, design: palette.metaDesign))
                    .tracking(0.8)
                    .foregroundStyle(palette.textSecondary)
                Spacer(minLength: 4)
                statusPill
            }

            Text(state.title)
                .font(.system(size: 14, weight: .semibold, design: palette.titleDesign))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)

            if state.status == .running {
                progressBar
            }

            Text(state.detail)
                .font(.system(size: 10.5))
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)

            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(palette.textTertiary)
                if state.status == .running {
                    Text(attributes.startedAt, style: .timer)
                        .font(.system(size: 9.5, weight: .medium, design: palette.metaDesign))
                        .foregroundStyle(palette.textSecondary)
                        .monospacedDigit()
                } else {
                    Text(state.elapsed)
                        .font(.system(size: 9.5, weight: .medium, design: palette.metaDesign))
                        .foregroundStyle(palette.textSecondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 4)
                actions
            }
        }
        .padding(14)
        .background(FlowCueWidgetBackground())
        .clipShape(RoundedRectangle(cornerRadius: palette.spec.radius, style: .continuous))
    }

    private var statusPill: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 4, height: 4)
            Text(statusText)
                .font(.system(size: 8.5, weight: .semibold, design: palette.metaDesign))
                .tracking(0.6)
                .foregroundStyle(statusColor)
        }
    }

    private var statusText: String {
        switch state.status {
        case .running: "LIVE"
        case .completed: "COMPLETED"
        case .failed: "FAILED"
        }
    }

    private var statusColor: Color {
        switch state.status {
        case .running, .completed: palette.success
        case .failed: palette.failure
        }
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.border)
                Capsule()
                    .fill(palette.accent)
                    .frame(width: max(8, proxy.size.width * 0.62))
            }
        }
        .frame(height: 3)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var actions: some View {
        switch state.status {
        case .running:
            EmptyView()
        case .completed:
            Link(destination: URL(string: "flowcue://chat")!) {
                Text("View changes")
                    .font(.system(size: 9.5, weight: .semibold, design: palette.metaDesign))
                    .foregroundStyle(palette.onAccent)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: min(12, palette.spec.radius), style: .continuous).fill(palette.accent))
            }
        case .failed:
            HStack(spacing: 6) {
                Link(destination: URL(string: "flowcue://chat")!) {
                    Text("Ignore")
                        .font(.system(size: 9.5, weight: .medium, design: palette.metaDesign))
                        .foregroundStyle(palette.textSecondary)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: min(12, palette.spec.radius), style: .continuous).fill(palette.surface))
                        .overlay(RoundedRectangle(cornerRadius: min(12, palette.spec.radius), style: .continuous).strokeBorder(palette.border))
                }
                Link(destination: URL(string: "flowcue://chat")!) {
                    Text("Retry")
                        .font(.system(size: 9.5, weight: .semibold, design: palette.metaDesign))
                        .foregroundStyle(palette.onAccent)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: min(12, palette.spec.radius), style: .continuous).fill(palette.accent))
                }
            }
        }
    }
}

struct LiveActivityPalette {
    let spec: FlowCueThemeSpec

    var accent: Color { Color(hex: spec.accent) }
    var canvas: Color { Color(hex: spec.background) }
    var surface: Color { Color(hex: spec.card) }
    var border: Color { spec.hasBorder ? Color(hex: spec.border) : .clear }
    var textPrimary: Color { Color(hex: spec.foreground) }
    var textSecondary: Color { Color(hex: spec.secondary) }
    var textTertiary: Color { Color(hex: spec.secondary).opacity(0.68) }
    var success: Color { Color(hex: "#5CD9B8") }
    var failure: Color { Color(hex: "#FF6B6B") }
    var onAccent: Color { Color(hex: "#0A0A12") }
    var titleDesign: Font.Design { spec.titleDesign }
    var metaDesign: Font.Design { spec.metaDesign }
}
