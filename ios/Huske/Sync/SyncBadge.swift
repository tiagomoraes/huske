// Where a recording is in the pipeline, shown beside its state ring:
// Recording · Waiting for your Mac · Sending · 42% · On your Mac · Queued on
// your Mac · Transcribing · 2 of 3 · Transcribed · Couldn't transcribe.
// Pure: easy to test.

import Foundation

enum SyncBadge: Equatable {
    case recording
    /// Saved on the phone; no Mac is paired, so nothing will happen yet.
    case onPhone
    case waitingForMac
    case uploading(fraction: Double)
    /// Verified on the Mac but not handed to its engine yet.
    case onMac
    case queued
    case transcribing(done: Int?, total: Int?, fraction: Double?)
    case transcribed
    case failed(reason: String?)
    case damaged

    enum Tone: Equatable {
        case recording, neutral, active, info, ok, error
    }

    init(recording: Recording, isPaired: Bool, uploadFraction: Double?) {
        switch recording.capture {
        case .inProgress:
            self = .recording
            return
        case .damaged:
            self = .damaged
            return
        case .complete:
            break
        }
        if recording.transcript != nil {
            self = .transcribed
            return
        }
        if let uploadFraction {
            self = .uploading(fraction: min(max(uploadFraction, 0), 1))
            return
        }
        if let failure = recording.sync.failure {
            self = .failed(reason: failure)
            return
        }
        guard isPaired else {
            self = .onPhone
            return
        }
        guard recording.sync.uploadedAt != nil, let remote = recording.sync.remote else {
            self = .waitingForMac
            return
        }
        switch remote.stage {
        case .unknown, .receiving:
            self = .waitingForMac
        case .received:
            self = .onMac
        case .queued:
            self = .queued
        case .transcribing:
            let counts = SyncBadge.chunkCounts(in: remote.detail)
            self = .transcribing(done: counts?.done, total: counts?.total, fraction: remote.progress)
        case .transcribed:
            self = .transcribed
        case .failed:
            self = .failed(reason: remote.detail)
        }
    }

    /// Sentence case, the user's terms ("your Mac"), numbers after a dot.
    var label: String {
        switch self {
        case .recording: return "Recording"
        case .onPhone: return "On this iPhone"
        case .waitingForMac: return "Waiting for your Mac"
        case let .uploading(fraction): return "Sending · \(Int((fraction * 100).rounded(.down)))%"
        case .onMac: return "On your Mac"
        case .queued: return "Queued on your Mac"
        case let .transcribing(done, total, fraction):
            if let done, let total, total > 1 { return "Transcribing · \(done) of \(total)" }
            if let fraction, fraction > 0 { return "Transcribing · \(Int((fraction * 100).rounded(.down)))%" }
            return "Transcribing"
        case .transcribed: return "Transcribed"
        case .failed: return "Couldn't transcribe"
        case .damaged: return "Recording damaged"
        }
    }

    var systemImage: String? {
        switch self {
        case .transcribed: return "checkmark"
        case .failed, .damaged: return "exclamationmark"
        case .uploading: return "arrow.up"
        default: return nil
        }
    }

    var tone: Tone {
        switch self {
        case .recording: return .recording
        case .onPhone, .waitingForMac: return .neutral
        case .uploading, .transcribing: return .active
        case .onMac, .queued: return .info
        case .transcribed: return .ok
        case .failed, .damaged: return .error
        }
    }

    /// Whether the dot should pulse (live work in progress).
    var isLive: Bool {
        switch self {
        case .recording, .uploading, .transcribing: return true
        default: return false
        }
    }

    var accessibilityLabel: String {
        switch self {
        case let .failed(reason?): return "Sync failed: \(reason)"
        case .transcribed: return "Transcribed"
        default: return label
        }
    }

    /// "2/3", "2 of 3", "chunk 2 of 3 chunks" → (2, 3).
    static func chunkCounts(in detail: String?) -> (done: Int, total: Int)? {
        guard let detail else { return nil }
        let pattern = #"(\d+)\s*(?:/|of)\s*(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: detail, range: NSRange(detail.startIndex..., in: detail)),
              let doneRange = Range(match.range(at: 1), in: detail),
              let totalRange = Range(match.range(at: 2), in: detail),
              let done = Int(detail[doneRange]), let total = Int(detail[totalRange]),
              total > 0, done <= total
        else { return nil }
        return (done, total)
    }
}
