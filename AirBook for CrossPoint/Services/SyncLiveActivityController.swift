import ActivityKit
import Foundation

/// Drives the sync Live Activity from SyncManager's phase transitions.
/// Requested when a sync starts (always foreground — the user just tapped
/// Sync), updated as books flow, ended with a short-lived final card on
/// done/error and dismissed immediately on cancel.
@MainActor
final class SyncLiveActivityController {
    private var activity: Activity<SyncActivityAttributes>?
    private var lastPushed: SyncActivityAttributes.ContentState?
    private var lastProgressPushAt = Date.distantPast

    init() {
        // Reap orphans from a previous run (app killed mid-sync) so a stale
        // card doesn't sit on the lock screen next to the new one.
        for stale in Activity<SyncActivityAttributes>.activities {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func sync(phase: SyncPhase, detail: String) {
        switch phase {
        case .idle, .cancelled:
            end(finalState: nil)
        case .done(let summary):
            end(finalState: .init(status: summary.summary, detail: "",
                                  progress: 1, finished: true, failed: false))
        case .error(let message):
            end(finalState: .init(status: "Sync failed", detail: message,
                                  progress: nil, finished: true, failed: true))
        default:
            guard phase.isActive else { return }
            push(contentState(for: phase, detail: detail))
        }
    }

    private func contentState(for phase: SyncPhase,
                              detail: String) -> SyncActivityAttributes.ContentState {
        var progress: Double?
        if case .executing(let step) = phase, step.bytesTotal > 0 {
            progress = Double(step.bytesTransferred) / Double(step.bytesTotal)
        }
        return .init(status: phase.statusMessage, detail: detail,
                     progress: progress, finished: false, failed: false)
    }

    private func push(_ state: SyncActivityAttributes.ContentState) {
        guard state != lastPushed else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        if activity == nil {
            activity = try? Activity.request(
                attributes: SyncActivityAttributes(),
                content: .init(state: state, staleDate: nil))
            lastPushed = state
            lastProgressPushAt = Date()
            return
        }

        // Status/detail changes go out immediately; byte-level progress churn
        // is throttled to ~1 update/s to keep ActivityKit traffic sane.
        let textChanged = state.status != lastPushed?.status || state.detail != lastPushed?.detail
        guard textChanged || Date().timeIntervalSince(lastProgressPushAt) >= 1 else { return }
        lastPushed = state
        lastProgressPushAt = Date()

        let current = activity
        Task { await current?.update(.init(state: state, staleDate: nil)) }
    }

    private func end(finalState: SyncActivityAttributes.ContentState?) {
        guard let current = activity else { return }
        activity = nil
        lastPushed = nil
        Task {
            if let finalState {
                // Leave the result card visible for a couple of minutes.
                await current.end(.init(state: finalState, staleDate: nil),
                                  dismissalPolicy: .after(.now + 120))
            } else {
                await current.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
