import ActivityKit
import SwiftUI
import WidgetKit

struct FlowCueLiveActivityWidget: Widget {
    private var palette: LiveActivityPalette { LiveActivityPalette(spec: FlowCueThemeSharing.currentSpec()) }

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FlowCueActivityAttributes.self) { context in
            FlowCueLiveActivityLockScreenView(
                attributes: context.attributes,
                state: context.state
            )
            .activityBackgroundTint(palette.canvas)
            .activitySystemActionForegroundColor(palette.accent)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        WidgetFaceMark(ink: palette.textPrimary, smile: palette.accent)
                            .frame(width: 18, height: 18)
                        Text(context.attributes.agent.uppercased())
                            .font(.system(size: 10, weight: .semibold, design: palette.metaDesign))
                            .foregroundStyle(palette.textSecondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(context.state.status == .failed ? palette.failure : palette.success)
                            .frame(width: 4, height: 4)
                        Text(context.state.status == .failed ? "FAILED" : (context.state.status == .completed ? "DONE" : "LIVE"))
                            .font(.system(size: 9, weight: .semibold, design: palette.metaDesign))
                            .tracking(0.5)
                            .foregroundStyle(palette.textSecondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(context.state.title)
                            .font(.system(size: 12, weight: .semibold, design: palette.titleDesign))
                            .foregroundStyle(palette.textPrimary)
                            .lineLimit(1)
                        Text(context.state.detail)
                            .font(.system(size: 9.5, design: palette.metaDesign))
                            .foregroundStyle(palette.textSecondary)
                            .lineLimit(1)
                    }
                }
            } compactLeading: {
                WidgetFaceMark(ink: palette.textPrimary, smile: palette.accent)
                    .frame(width: 16, height: 16)
            } compactTrailing: {
                Circle()
                    .fill(context.state.status == .failed ? palette.failure : palette.success)
                    .frame(width: 5, height: 5)
            } minimal: {
                WidgetFaceMark(ink: palette.textPrimary, smile: palette.accent)
                    .frame(width: 16, height: 16)
            }
            .widgetURL(URL(string: "flowcue://chat"))
            .keylineTint(palette.accent)
        }
    }
}
