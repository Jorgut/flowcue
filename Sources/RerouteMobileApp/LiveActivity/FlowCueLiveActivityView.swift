import SwiftUI

struct FlowCueLiveActivityLockScreenView: View {
    let attributes: FlowCueActivityAttributes
    let state: FlowCueActivityAttributes.ContentState

    private var palette: LiveActivityPalette { LiveActivityPalette(tokens: .airyDark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Text("FLOWCUE · \(attributes.agent.uppercased())")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(palette.textSecondary)
                Spacer(minLength: 4)
                statusPill
            }

            Text(state.title)
                .font(.system(size: 14, weight: .semibold))
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
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                        .monospacedDigit()
                } else {
                    Text(state.elapsed)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 4)
                actions
            }
        }
        .padding(14)
        .background(FlowCueWidgetBackground())
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var statusPill: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 4, height: 4)
            Text(statusText)
                .font(.system(size: 8.5, weight: .semibold))
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
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(palette.onAccent)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Capsule().fill(palette.accent))
            }
        case .failed:
            HStack(spacing: 6) {
                Link(destination: URL(string: "flowcue://chat")!) {
                    Text("Ignore")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Capsule().fill(palette.surface))
                        .overlay(Capsule().strokeBorder(palette.border))
                }
                Link(destination: URL(string: "flowcue://chat")!) {
                    Text("Retry")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(palette.onAccent)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Capsule().fill(palette.accent))
                }
            }
        }
    }
}

struct LiveActivityPalette {
    let tokens: FlowCueTokens

    var accent: Color { Color(hex: tokens.accent) }
    var canvas: Color { Color(hex: tokens.canvas) }
    var surface: Color { Color(hex: tokens.surface) }
    var border: Color { Color(hex: tokens.border) }
    var textPrimary: Color { Color(hex: tokens.textPrimary) }
    var textSecondary: Color { Color(hex: tokens.textSecondary) }
    var textTertiary: Color { Color(hex: tokens.textTertiary) }
    var success: Color { Color(hex: tokens.success) }
    var failure: Color { Color(hex: tokens.failure) }
    var onAccent: Color { Color(hex: "#1C1A29") }
}
