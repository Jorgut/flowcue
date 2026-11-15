import SwiftUI
import WidgetKit

struct FlowCueWidgetView: View {
    let snapshot: FlowCueWidgetSnapshot
    let family: WidgetFamily

    private var palette: WidgetPalette { WidgetPalette(tokens: .airyDark) }

    var body: some View {
        Group {
            switch family {
            case .systemMedium:
                medium
            case .systemLarge:
                large
            default:
                small
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text("FLOWCUE")
                    .font(.system(size: 8.5, weight: .semibold))
                    .tracking(0.9)
                    .foregroundStyle(palette.textSecondary)
                Spacer(minLength: 4)
                WidgetFaceMark(ink: palette.textPrimary, smile: palette.accent)
                    .frame(width: 16, height: 16)
            }

            Spacer(minLength: 0)

            Text("\(snapshot.totalIdeas)")
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            Text("IDEAS")
                .font(.system(size: 8.5, weight: .medium))
                .tracking(1.1)
                .foregroundStyle(palette.textSecondary)
                .padding(.top, 1)
        }
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 0) {
            widgetHeader
                .padding(.bottom, 6)

            HStack(alignment: .firstTextBaseline) {
                Text("\(snapshot.totalIdeas)")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                Spacer(minLength: 8)
                Text("IDEAS")
                    .font(.system(size: 8.5, weight: .medium))
                    .tracking(1.1)
                    .foregroundStyle(palette.textSecondary)
            }

            VStack(spacing: 8) {
                ForEach(snapshot.ideas.prefix(2)) { idea in
                    WidgetIdeaRow(idea: idea, showsStatus: false, palette: palette)
                }
            }
            .padding(.top, 10)
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("FLOWCUE · INBOX")
                    .font(.system(size: 8.5, weight: .semibold))
                    .tracking(0.9)
                    .foregroundStyle(palette.textSecondary)
                Spacer(minLength: 4)
                WidgetStatusPill(status: snapshot.status, palette: palette)
            }

            HStack(alignment: .firstTextBaseline) {
                Text("\(snapshot.totalIdeas)")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                Spacer(minLength: 8)
                Text("IDEAS")
                    .font(.system(size: 8.5, weight: .medium))
                    .tracking(1.1)
                    .foregroundStyle(palette.textSecondary)
            }
            .padding(.top, 6)

            VStack(spacing: 11) {
                ForEach(snapshot.ideas.prefix(4)) { idea in
                    WidgetIdeaRow(idea: idea, showsStatus: true, palette: palette)
                }
            }
            .padding(.top, 12)

            Spacer(minLength: 6)

            Link(destination: URL(string: "flowcue://capture")!) {
                Text("+ New idea")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(palette.accent.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(palette.accent.opacity(0.35))
                    )
            }
        }
    }

    private var widgetHeader: some View {
        HStack(spacing: 4) {
            Text("FLOWCUE")
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(palette.textSecondary)
            Spacer(minLength: 4)
            WidgetStatusPill(status: snapshot.status, palette: palette)
        }
    }
}

struct FlowCueWidgetBackground: View {
    private let tokens = FlowCueTokens.airyDark

    var body: some View {
        ZStack {
            Color(hex: tokens.canvas)
            RadialGradient(
                colors: [Color(hex: tokens.accent).opacity(0.34), .clear],
                center: UnitPoint(x: 0.18, y: 0.08),
                startRadius: 0,
                endRadius: 300
            )
        }
    }
}

private struct WidgetStatusPill: View {
    let status: String
    let palette: WidgetPalette

    private var isLocal: Bool { status == "LOCAL" }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isLocal ? palette.textTertiary : palette.accent)
                .frame(width: 4, height: 4)
            Text(status)
                .font(.system(size: 8, weight: .medium))
                .tracking(0.6)
                .foregroundStyle(isLocal ? palette.textTertiary : palette.textSecondary)
        }
    }
}

private struct WidgetIdeaRow: View {
    let idea: FlowCueWidgetSnapshot.Idea
    let showsStatus: Bool
    let palette: WidgetPalette

    private var dotColor: Color {
        switch idea.status {
        case "QUEUED": palette.accent
        case "FAILED": palette.failure
        case "NEEDS CHECK": palette.warning
        default: palette.textTertiary
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 4, height: 4)
            Text(idea.text)
                .font(.system(size: 10.5))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if showsStatus {
                Text(idea.status)
                    .font(.system(size: 8, weight: .medium))
                    .tracking(0.4)
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct WidgetPalette {
    let tokens: FlowCueTokens

    var accent: Color { Color(hex: tokens.accent) }
    var surface: Color { Color(hex: tokens.surface) }
    var border: Color { Color(hex: tokens.border) }
    var textPrimary: Color { Color(hex: tokens.textPrimary) }
    var textSecondary: Color { Color(hex: tokens.textSecondary) }
    var textTertiary: Color { Color(hex: tokens.textTertiary) }
    var success: Color { Color(hex: tokens.success) }
    var warning: Color { Color(hex: tokens.warning) }
    var failure: Color { Color(hex: tokens.failure) }
}

private struct WidgetFaceMark: View {
    var ink: Color
    var smile: Color

    var body: some View {
        Canvas { context, size in
            let unit = min(size.width, size.height) / 96
            context.scaleBy(x: unit, y: unit)

            for center in [CGPoint(x: 32, y: 34), CGPoint(x: 64, y: 34)] {
                context.fill(
                    Path(ellipseIn: CGRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18)),
                    with: .color(ink)
                )
            }
            context.fill(
                Path(roundedRect: CGRect(x: 42, y: 40, width: 12, height: 18), cornerRadius: 6),
                with: .color(ink)
            )

            var mouth = Path()
            mouth.move(to: CGPoint(x: 26, y: 64))
            mouth.addQuadCurve(to: CGPoint(x: 70, y: 64), control: CGPoint(x: 48, y: 88.3))
            context.stroke(
                mouth,
                with: .color(smile),
                style: StrokeStyle(lineWidth: 14, lineCap: .round)
            )
        }
        .accessibilityHidden(true)
    }
}
