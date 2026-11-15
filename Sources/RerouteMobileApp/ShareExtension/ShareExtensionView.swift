import SwiftUI

struct ShareExtensionView: View {
    let initialText: String
    let onSave: (String, FlowCueShareTarget) -> Void
    let onCancel: () -> Void

    @State private var target: FlowCueShareTarget = .inbox
    @Environment(\.colorScheme) private var colorScheme

    private var trimmedText: String {
        initialText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var palette: SharePalette {
        SharePalette(tokens: FlowCueMobileTheme.tokens(for: colorScheme))
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
                .font(.system(size: 9.5))
                .foregroundStyle(palette.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(palette.canvas.ignoresSafeArea())
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
                .font(.system(size: 13, weight: .semibold))
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
                .font(.system(size: 9, weight: .medium))
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
            RoundedRectangle(cornerRadius: FlowCueMetrics.radiusCard, style: .continuous)
                .fill(palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FlowCueMetrics.radiusCard, style: .continuous)
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
                    Capsule()
                        .fill(selected ? palette.accent : palette.surface)
                )
                .overlay(
                    Capsule()
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
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.onAccent)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Capsule().fill(palette.accent))
        }
        .buttonStyle(.plain)
        .disabled(trimmedText.isEmpty)
        .opacity(trimmedText.isEmpty ? 0.45 : 1)
    }
}

private struct SharePalette {
    let tokens: FlowCueTokens

    var accent: Color { Color(hex: tokens.accent) }
    var canvas: Color { Color(hex: tokens.canvas) }
    var surface: Color { Color(hex: tokens.surface) }
    var border: Color { Color(hex: tokens.border) }
    var textPrimary: Color { Color(hex: tokens.textPrimary) }
    var textSecondary: Color { Color(hex: tokens.textSecondary) }
    var textTertiary: Color { Color(hex: tokens.textTertiary) }
    var onAccent: Color { Color(hex: "#1C1A29") }
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
