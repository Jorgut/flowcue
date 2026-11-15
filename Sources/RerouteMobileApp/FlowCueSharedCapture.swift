import Foundation

enum FlowCueShareTarget: String, Codable, Sendable {
    case inbox
    case codex
}

struct FlowCueSharedCapture: Codable, Sendable {
    var text: String
    var target: FlowCueShareTarget
    var createdAt: Date
}

/// App 与 Share Extension 通过 App Group 传递待保存的分享内容。
enum FlowCueSharedCaptureStore {
    static let appGroup = "group.com.archintera.FlowCue"
    private static let key = "FlowCue.pendingSharedCaptures"

    static func append(_ capture: FlowCueSharedCapture) {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return }
        defaults.synchronize()
        var items = load(defaults)
        items.append(capture)
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: key)
        defaults.synchronize()
    }

    static func drain() -> [FlowCueSharedCapture] {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return [] }
        defaults.synchronize()
        let items = load(defaults)
        defaults.removeObject(forKey: key)
        defaults.synchronize()
        return items
    }

    private static func load(_ defaults: UserDefaults) -> [FlowCueSharedCapture] {
        guard let data = defaults.data(forKey: key),
              let items = try? JSONDecoder().decode([FlowCueSharedCapture].self, from: data) else {
            return []
        }
        return items
    }
}
