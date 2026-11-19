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
        /// Coarse input level, 0…4, for the mini meter. Updated sparingly.
        var level: Int

        var elapsed: TimeInterval {
            (pausedAt ?? Date()).timeIntervalSince(timerStart)
        }

        var timerRange: ClosedRange<Date> {
            // The upper bound only has to be far enough away to never be reached.
            timerStart...timerStart.addingTimeInterval(60 * 60 * 24)
        }
    }

    var recordingID: String
    var startedAt: Date
}

/// Maps a dBFS power reading to the coarse 0…4 level the Live Activity shows.
enum CoarseLevel {
    static func from(dBFS power: Float) -> Int {
        switch power {
        case ..<(-50): return 0
        case ..<(-38): return 1
        case ..<(-28): return 2
        case ..<(-18): return 3
        default: return 4
        }
    }
}
