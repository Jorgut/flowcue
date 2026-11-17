import SwiftUI
import WidgetKit

struct FlowCueWidgetView: View {
    let snapshot: FlowCueWidgetSnapshot
    let family: WidgetFamily

    private var palette: WidgetPalette { WidgetPalette(spec: FlowCueThemeSharing.currentSpec()) }

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
                    .font(.system(size: 8.5, weight: .semibold, design: palette.metaDesign))
                    .tracking(0.9)
                    .foregroundStyle(palette.textSecondary)
                Spacer(minLength: 4)
                WidgetFaceMark(ink: palette.textPrimary, smile: palette.accent)
                    .frame(width: 16, height: 16)
            }

            Spacer(minLength: 0)

            Text("\(snapshot.totalIdeas)")
                .font(.system(size: 46, weight: .semibold, design: palette.titleDesign))
                .foregroundStyle(palette.textPrimary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            Text("IDEAS")
                .font(.system(size: 8.5, weight: .medium, design: palette.metaDesign))
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
                    .font(.system(size: 30, weight: .semibold, design: palette.titleDesign))
                    .foregroundStyle(palette.textPrimary)
                Spacer(minLength: 8)
                Text("IDEAS")
                    .font(.system(size: 8.5, weight: .medium, design: palette.metaDesign))
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
                    .font(.system(size: 8.5, weight: .semibold, design: palette.metaDesign))
                    .tracking(0.9)
                    .foregroundStyle(palette.textSecondary)
                Spacer(minLength: 4)
                WidgetStatusPill(status: snapshot.status, palette: palette)
            }

            HStack(alignment: .firstTextBaseline) {
                Text("\(snapshot.totalIdeas)")
                    .font(.system(size: 32, weight: .semibold, design: palette.titleDesign))
                    .foregroundStyle(palette.textPrimary)
                Spacer(minLength: 8)
                Text("IDEAS")
                    .font(.system(size: 8.5, weight: .medium, design: palette.metaDesign))
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
                    .font(.system(size: 10.5, weight: .semibold, design: palette.titleDesign))
                    .foregroundStyle(palette.accent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: min(12, palette.spec.radius), style: .continuous)
                            .fill(palette.accent.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: min(12, palette.spec.radius), style: .continuous)
                            .strokeBorder(palette.accent.opacity(0.35))
                    )
            }
        }
    }

    private var widgetHeader: some View {
        HStack(spacing: 4) {
            Text("FLOWCUE")
                .font(.system(size: 8.5, weight: .semibold, design: palette.metaDesign))
                .tracking(0.9)
                .foregroundStyle(palette.textSecondary)
            Spacer(minLength: 4)
            WidgetStatusPill(status: snapshot.status, palette: palette)
        }
    }
}

struct FlowCueWidgetBackground: View {
    private var spec: FlowCueThemeSpec { FlowCueThemeSharing.currentSpec() }

    var body: some View {
        let spec = spec
        ZStack {
            Color(hex: spec.background)
            if spec.glow {
                RadialGradient(
                    colors: [Color(hex: spec.accent).opacity(0.34), .clear],
                    center: UnitPoint(x: 0.18, y: 0.08),
                    startRadius: 0,
                    endRadius: 300
                )
            }
            if spec.grid {
                WidgetGridBackground(spec: spec)
            }
        }
    }
}

private struct WidgetGridBackground: View {
    let spec: FlowCueThemeSpec

    var body: some View {
        let color = (spec.hasBorder ? Color(hex: spec.border) : Color.white.opacity(0.08)).opacity(0.55)
        Canvas { context, size in
            var path = Path()
            var x: CGFloat = 0
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += 28
            }
            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += 28
            }
            context.stroke(path, with: .color(color), lineWidth: 1)
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
                .font(.system(size: 8, weight: .medium, design: palette.metaDesign))
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
                    .font(.system(size: 8, weight: .medium, design: palette.metaDesign))
                    .tracking(0.4)
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct WidgetPalette {
    let spec: FlowCueThemeSpec

    var accent: Color { Color(hex: spec.accent) }
    var surface: Color { Color(hex: spec.card) }
    var border: Color { spec.hasBorder ? Color(hex: spec.border) : .clear }
    var textPrimary: Color { Color(hex: spec.foreground) }
    var textSecondary: Color { Color(hex: spec.secondary) }
    var textTertiary: Color { Color(hex: spec.secondary).opacity(0.68) }
    var success: Color { Color(hex: "#5CD9B8") }
    var warning: Color { Color(hex: "#F0B429") }
    var failure: Color { Color(hex: "#FF6B6B") }
    var titleDesign: Font.Design { spec.titleDesign }
    var metaDesign: Font.Design { spec.metaDesign }
}

struct WidgetFaceMark: View {
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
