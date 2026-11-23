// The Live Activity's data model, shared by the app (which starts and updates
// it) and the widget extension (which renders it).

import ActivityKit
import Foundation

struct RecordingActivityAttributes: ActivityAttributes {
    /// Everything that changes while recording. Kept small: the system caps
    /// the encoded size of a Live Activity update.
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case recording
            case paused
            /// The recording was stopped and saved; shown briefly before the
            /// activity is dismissed.
            case saved
        }

        var phase: Phase
        var title: String
        /// Virtual start of the elapsed timer: `now - elapsed` at the last
        /// resume. `Text(timerInterval:pauseTime:)` counts up from here.
        var timerStart: Date
        /// Set while paused (and when saved) so the timer freezes at
        /// `pausedAt - timerStart`.
        var pausedAt: Date?
        /// Why it paused, in a few words ("Phone call"), or nil for a user pause.
        var pauseReason: String?

        var elapsed: TimeInterval {
            (pausedAt ?? Date()).timeIntervalSince(timerStart)
        }

        /// From just before the hour the timer reads "1:02:03" instead of
        /// "12:34", so the compact island needs a wider slot. The app pushes an
        /// update when this flips (`LiveActivityController.refreshForElapsedTime`).
        var needsHourWidth: Bool { elapsed >= 59 * 60 + 30 }

        /// Width of the compact island timer (Plex Sans Medium 14, tabular).
        var compactTimerWidth: CGFloat { needsHourWidth ? 54 : 41 }

        var timerRange: ClosedRange<Date> {
            // The upper bound only has to be far enough away to never be reached.
            timerStart...timerStart.addingTimeInterval(60 * 60 * 24)
        }
    }

    var recordingID: String
    var startedAt: Date
}
