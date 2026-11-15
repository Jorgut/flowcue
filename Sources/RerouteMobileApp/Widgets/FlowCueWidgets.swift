import SwiftUI
import WidgetKit

struct FlowCueWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: FlowCueWidgetSnapshot
}

struct FlowCueWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> FlowCueWidgetEntry {
        FlowCueWidgetEntry(date: .now, snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (FlowCueWidgetEntry) -> Void) {
        completion(FlowCueWidgetEntry(date: .now, snapshot: FlowCueWidgetSnapshotStore.read() ?? .sample))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FlowCueWidgetEntry>) -> Void) {
        let entry = FlowCueWidgetEntry(date: .now, snapshot: FlowCueWidgetSnapshotStore.read() ?? .empty)
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: .now) ?? .now.addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct FlowCueWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: FlowCueWidgetEntry

    var body: some View {
        FlowCueWidgetView(snapshot: entry.snapshot, family: family)
    }
}

struct FlowCueIdeasWidget: Widget {
    private let kind = "FlowCueIdeas"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FlowCueWidgetProvider()) { entry in
            FlowCueWidgetEntryView(entry: entry)
                .containerBackground(for: .widget) {
                    FlowCueWidgetBackground()
                }
        }
        .configurationDisplayName("FlowCue ideas")
        .description("Your latest ideas and how many are in the inbox.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

@main
struct FlowCueWidgets: WidgetBundle {
    var body: some Widget {
        FlowCueIdeasWidget()
        FlowCueLiveActivityWidget()
    }
}
