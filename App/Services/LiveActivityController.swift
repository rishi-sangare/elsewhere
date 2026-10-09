import ActivityKit
import Foundation

/// Lock screen + Dynamic Island status with a Stop button, so you always know
/// whether your location is changed — even while using other apps.
@MainActor
final class LiveActivityController {
    private var activity: Activity<SpoofActivityAttributes>?
    private var lastState: SpoofActivityAttributes.ContentState?
    private var lastPush: Date = .distantPast

    func start(startedAt: Date, state: SpoofActivityAttributes.ContentState) {
        guard activity == nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        activity = try? Activity.request(
            attributes: SpoofActivityAttributes(startedAt: startedAt),
            content: .init(state: state, staleDate: nil)
        )
        lastState = state
        lastPush = Date()
    }

    /// Throttled: health changes go out immediately, everything else ≤ every 3 s.
    func update(_ state: SpoofActivityAttributes.ContentState) {
        guard let activity, state != lastState else { return }
        let urgent = state.health != lastState?.health
        guard urgent || Date().timeIntervalSince(lastPush) > 3 else { return }
        lastState = state
        lastPush = Date()
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
