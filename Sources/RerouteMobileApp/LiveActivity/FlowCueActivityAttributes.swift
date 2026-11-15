import ActivityKit
import Foundation

enum FlowCueActivityStatus: String, Codable, Hashable {
    case running
    case completed
    case failed
}

struct FlowCueActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var detail: String
        var status: FlowCueActivityStatus
        var elapsed: String
        var updatedAt: Date
    }

    var sessionID: String
    var agent: String
    var startedAt: Date
}
