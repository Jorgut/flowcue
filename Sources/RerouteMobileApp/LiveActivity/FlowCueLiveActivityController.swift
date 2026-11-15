@preconcurrency import ActivityKit
import Foundation
import Observation

@MainActor
@Observable
final class FlowCueLiveActivityController {
    static let shared = FlowCueLiveActivityController()

    private(set) var activity: Activity<FlowCueActivityAttributes>?
    private(set) var lastError: String?

    var isActive: Bool { activity != nil }
    var startedAt: Date? { activity?.attributes.startedAt }

    private init() {
        activity = Activity<FlowCueActivityAttributes>.activities.first
    }

    func start(attributes: FlowCueActivityAttributes, state: FlowCueActivityAttributes.ContentState) {
        guard activity == nil else { return }
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func update(_ state: FlowCueActivityAttributes.ContentState) {
        guard activity != nil else { return }
        Task { @MainActor in
            await self.performUpdate(state)
        }
    }

    func stop(_ state: FlowCueActivityAttributes.ContentState) {
        guard activity != nil else { return }
        Task { @MainActor in
            await self.performStop(state)
        }
    }

    @MainActor
    private func performUpdate(_ state: FlowCueActivityAttributes.ContentState) async {
        guard let activity else { return }
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }

    @MainActor
    private func performStop(_ state: FlowCueActivityAttributes.ContentState) async {
        guard let activity else { return }
        self.activity = nil
        await activity.end(
            ActivityContent(state: state, staleDate: nil),
            dismissalPolicy: .after(.now + 8)
        )
    }
}
