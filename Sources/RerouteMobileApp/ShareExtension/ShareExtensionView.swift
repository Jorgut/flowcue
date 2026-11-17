import SwiftUI

struct ShareExtensionView: View {
    let initialText: String
    let onSave: (String, FlowCueShareTarget) -> Void
    let onCancel: () -> Void

    @State private var target: FlowCueShareTarget = .inbox

    private var trimmedText: String {
        initialText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var palette: SharePalette {
        SharePalette(spec: FlowCueThemeSharing.currentSpec())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            textCard
                .padding(.top, 14)
            targetChips
                .padding(.top, 14)
            Spacer(minLength: 12)
            saveButton
            Text("Saves locally · offline safe.")
                .font(.system(size: 9.5, design: palette.metaDesign))
                .foregroundStyle(palette.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(ShareBackground(spec: palette.spec))
    }

    private var header: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(palette.surface)
                Circle().strokeBorder(palette.border)
                ShareFaceMark(ink: palette.textPrimary, smile: palette.accent)
                    .frame(width: 16, height: 16)
            }
            .frame(width: 28, height: 28)

            Text("FlowCue")
                .font(.system(size: 13, weight: .semibold, design: palette.titleDesign))
                .foregroundStyle(palette.textPrimary)

            Spacer()

            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel")
        }
    }

    private var textCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SHARED TEXT")
                .font(.system(size: 9, weight: .medium, design: palette.metaDesign))
                .tracking(0.8)
                .foregroundStyle(palette.textSecondary)
            Text(trimmedText.isEmpty ? "Nothing to save." : trimmedText)
                .font(.system(size: 12.5))
                .foregroundStyle(trimmedText.isEmpty ? palette.textTertiary : palette.textPrimary)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: palette.spec.radius, style: .continuous)
                .fill(palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: palette.spec.radius, style: .continuous)
                .strokeBorder(palette.border)
        )
    }

    private var targetChips: some View {
        HStack(spacing: 8) {
            chip("Inbox", value: .inbox)
            chip("Codex", value: .codex)
            Spacer(minLength: 0)
        }
    }

    private func chip(_ title: String, value: FlowCueShareTarget) -> some View {
        let selected = target == value
        return Button {
            target = value
        } label: {
            Text(title)
                .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? palette.onAccent : palette.textPrimary)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: min(12, palette.spec.radius), style: .continuous)
                        .fill(selected ? palette.accent : palette.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: min(12, palette.spec.radius), style: .continuous)
                        .strokeBorder(selected ? Color.clear : palette.border)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var saveButton: some View {
        Button {
            onSave(trimmedText, target)
        } label: {
            Text("Save")
                .font(.system(size: 14, weight: .semibold, design: palette.titleDesign))
                .foregroundStyle(palette.onAccent)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(RoundedRectangle(cornerRadius: palette.spec.radius, style: .continuous).fill(palette.accent))
        }
        .buttonStyle(.plain)
        .disabled(trimmedText.isEmpty)
        .opacity(trimmedText.isEmpty ? 0.45 : 1)
    }
}

private struct SharePalette {
    let spec: FlowCueThemeSpec

    var accent: Color { Color(hex: spec.accent) }
    var canvas: Color { Color(hex: spec.background) }
    var surface: Color { Color(hex: spec.card) }
    var border: Color { spec.hasBorder ? Color(hex: spec.border) : .clear }
    var textPrimary: Color { Color(hex: spec.foreground) }
    var textSecondary: Color { Color(hex: spec.secondary) }
    var textTertiary: Color { Color(hex: spec.secondary).opacity(0.68) }
    var onAccent: Color { Color(hex: "#0A0A12") }
    var titleDesign: Font.Design { spec.titleDesign }
    var metaDesign: Font.Design { spec.metaDesign }
}

private struct ShareBackground: View {
    let spec: FlowCueThemeSpec

    var body: some View {
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
                ShareGridBackground(spec: spec)
            }
        }
        .ignoresSafeArea()
    }
}

private struct ShareGridBackground: View {
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

private struct ShareFaceMark: View {
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
