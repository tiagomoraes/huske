// Starts, updates and ends the recording Live Activity (Lock Screen +
// Dynamic Island). The timer runs on the system clock, so updates are only
// needed on state changes and for the coarse level meter (throttled).

import ActivityKit
import Foundation
import OSLog

private let log = Logger(subsystem: "cloud.tiagomoraes.huske.ios", category: "live-activity")

@MainActor
final class LiveActivityController {
    private var activity: Activity<RecordingActivityAttributes>?
    private var state: RecordingActivityAttributes.ContentState?
    private var lastLevelPush = Date.distantPast
    private let levelInterval: TimeInterval = 2

    var isEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func start(recordingID: String, title: String, startedAt: Date) {
        guard isEnabled else {
            log.info("Live Activities are disabled; recording without one")
            return
        }
        let initial = RecordingActivityAttributes.ContentState(
            phase: .recording, title: title, timerStart: Date(), pausedAt: nil,
            pauseReason: nil, level: 0)
        do {
            activity = try Activity.request(
                attributes: RecordingActivityAttributes(recordingID: recordingID, startedAt: startedAt),
                content: ActivityContent(state: initial, staleDate: nil),
                pushType: nil)
            state = initial
            log.info("Live Activity started: \(self.activity?.id ?? "-", privacy: .public)")
        } catch {
            // Live Activities are a convenience; recording goes on without one.
            log.error("Live Activity request failed: \(error.localizedDescription, privacy: .public)")
            activity = nil
        }
    }

    func update(_ newState: RecordingActivityAttributes.ContentState) {
        state = newState
        lastLevelPush = Date()
        push(newState)
    }

    /// Coarse meter refresh: only when the level changed and not more often
    /// than every `levelInterval` seconds (Live Activity update budget).
    func updateLevel(_ level: Int) {
        guard var current = state, current.phase == .recording, current.level != level,
              Date().timeIntervalSince(lastLevelPush) >= levelInterval else { return }
        current.level = level
        state = current
        lastLevelPush = Date()
        push(current)
    }

    /// Shows a short "Saved" state, then dismisses.
    func end(title: String, elapsed: TimeInterval) {
        guard let activity else { return }
        let now = Date()
        let final = RecordingActivityAttributes.ContentState(
            phase: .saved, title: title, timerStart: now.addingTimeInterval(-elapsed),
            pausedAt: now, pauseReason: nil, level: 0)
        self.activity = nil
        state = nil
        Task {
            await activity.end(ActivityContent(state: final, staleDate: nil),
                               dismissalPolicy: .after(now.addingTimeInterval(4)))
        }
    }

    /// Ends activities left over from a previous run (the app was killed while
    /// recording) or that don't belong to the recording in progress.
    func endStale(keeping recordingID: String?) async {
        for leftover in Activity<RecordingActivityAttributes>.activities
        where leftover.attributes.recordingID != recordingID {
            await leftover.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func push(_ content: RecordingActivityAttributes.ContentState) {
        guard let activity else { return }
        Task {
            await activity.update(ActivityContent(state: content, staleDate: nil))
        }
    }
}
