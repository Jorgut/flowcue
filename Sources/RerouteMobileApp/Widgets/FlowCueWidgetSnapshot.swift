import Foundation

struct FlowCueWidgetSnapshot: Codable, Sendable {
    struct Idea: Codable, Sendable, Identifiable {
        let text: String
        let status: String
        let updatedAt: Date

        var id: String { "\(text)|\(updatedAt.timeIntervalSince1970)" }
    }

    var ideas: [Idea]
    var totalIdeas: Int
    var status: String
    var updatedAt: Date

    static let empty = FlowCueWidgetSnapshot(
        ideas: [],
        totalIdeas: 0,
        status: "LOCAL",
        updatedAt: .now
    )

    static let sample: FlowCueWidgetSnapshot = {
        let now = Date.now
        return FlowCueWidgetSnapshot(
            ideas: [
                Idea(text: "Retry backoff feels too slow", status: "DRAFT", updatedAt: now),
                Idea(text: "Character should blink once on save", status: "QUEUED", updatedAt: now),
                Idea(text: "Share sheet for Safari", status: "QUEUED", updatedAt: now),
                Idea(text: "Widget for quick capture", status: "DRAFT", updatedAt: now)
            ],
            totalIdeas: 4,
            status: "CODEX 12MS",
            updatedAt: now
        )
    }()
}

enum FlowCueWidgetSnapshotStore {
    static let appGroup = "group.com.archintera.FlowCue"
    private static let key = "FlowCue.widgetSnapshot"

    static func write(_ snapshot: FlowCueWidgetSnapshot) {
        guard let defaults = UserDefaults(suiteName: appGroup),
              let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
        defaults.synchronize()
    }

    static func read() -> FlowCueWidgetSnapshot? {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return nil }
        defaults.synchronize()
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(FlowCueWidgetSnapshot.self, from: data)
    }
}
