// Starts, updates and ends the recording Live Activity (Lock Screen +
// Dynamic Island). The timer runs on the system clock, so updates are only
// needed on state changes (and once, when the compact timer widens at the
// hour). There is no level meter: see RecordingLiveActivity.swift.

import ActivityKit
import Foundation
import OSLog

private let log = Logger(subsystem: "cloud.tiagomoraes.huske.ios", category: "live-activity")

@MainActor
final class LiveActivityController {
    private var activity: Activity<RecordingActivityAttributes>?
    private var state: RecordingActivityAttributes.ContentState?
    private var lastPushedHourWidth = false

    var isEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// Returns whether an activity is showing. In the foreground that is a
    /// convenience; for a background start iOS requires it.
    @discardableResult
    func start(recordingID: String, title: String, startedAt: Date) -> Bool {
        guard isEnabled else {
            log.info("Live Activities are disabled; recording without one")
            return false
        }
        let initial = RecordingActivityAttributes.ContentState(
            phase: .recording, title: title, timerStart: Date(), pausedAt: nil,
            pauseReason: nil)
        do {
            activity = try Activity.request(
                attributes: RecordingActivityAttributes(recordingID: recordingID, startedAt: startedAt),
                content: ActivityContent(state: initial, staleDate: nil),
                pushType: nil)
            state = initial
            lastPushedHourWidth = false
            log.info("Live Activity started: \(self.activity?.id ?? "-", privacy: .public)")
            return true
        } catch {
            // In the foreground recording goes on without one.
            log.error("Live Activity request failed: \(error.localizedDescription, privacy: .public)")
            activity = nil
            return false
        }
    }

    func update(_ newState: RecordingActivityAttributes.ContentState) {
        state = newState
        lastPushedHourWidth = newState.needsHourWidth
        push(newState)
    }

    /// Called on the recorder's tick. The timer runs on the system clock, so
    /// the only reason to push while recording is the compact island's
    /// timer slot widening just before the hour ("1:00:00").
    func refreshForElapsedTime() {
        guard let current = state, current.phase == .recording,
              current.needsHourWidth != lastPushedHourWidth else { return }
        update(current)
    }

    /// Shows a short "Saved" state, then dismisses.
    func end(title: String, elapsed: TimeInterval) {
        guard let activity else { return }
        let now = Date()
        let final = RecordingActivityAttributes.ContentState(
            phase: .saved, title: title, timerStart: now.addingTimeInterval(-elapsed),
            pausedAt: now, pauseReason: nil)
        self.activity = nil
        state = nil
        Task {
            await activity.end(ActivityContent(state: final, staleDate: nil),
                               dismissalPolicy: .after(now.addingTimeInterval(4)))
        }
    }

    /// The recording didn't start after all: remove it right away.
    func cancel() {
        guard let activity else { return }
        self.activity = nil
        state = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
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
