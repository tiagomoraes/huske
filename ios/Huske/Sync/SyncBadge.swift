// Where a recording is in the pipeline, shown beside its state ring:
// Recording · Waiting for your Mac · Sending · 42% · Couldn't send · On your
// Mac · Queued on your Mac · Trying again on your Mac · Transcribing · 2 of 3 ·
// Transcribed · Partly transcribed · Couldn't transcribe. Pure: easy to test.

import Foundation

enum SyncBadge: Equatable {
    case recording
    /// Saved on the phone; no Mac is paired, so nothing will happen yet.
    case onPhone
    case waitingForMac
    case uploading(fraction: Double)
    /// It never got to the Mac, and sending it again by itself won't help
    /// (too large, its audio file is gone…). The way out is Retry.
    case sendFailed(reason: String?)
    /// Verified on the Mac but not handed to its engine yet.
    case onMac
    case queued
    /// The Mac hit an error with it and will try again on its own. `attempt`
    /// is the try that comes next, of `maxAttempts`, when the Mac says.
    case retryingOnMac(reason: String?, attempt: Int? = nil, maxAttempts: Int? = nil)
    case transcribing(done: Int?, total: Int?, fraction: Double?)
    case transcribed
    /// The Mac gave up, but some parts were transcribed and are on this
    /// iPhone: `done` of `total`, when the Mac said.
    case partial(done: Int?, total: Int?)
    /// The Mac has it and gave up transcribing it.
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
            self = .sendFailed(reason: failure)
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
        case .received, .queued:
            if remote.retrying == true {
                // The Mac said so in so many fields; its text only adds why.
                let reason = SyncBadge.retryReason(in: remote.detail) ?? remote.detail ?? ""
                self = .retryingOnMac(
                    reason: reason.isEmpty ? nil : reason, attempt: remote.attempt,
                    maxAttempts: remote.maxAttempts)
            } else if let reason = SyncBadge.retryReason(in: remote.detail) {
                // An older Mac only says it in words.
                self = .retryingOnMac(reason: reason.isEmpty ? nil : reason)
            } else {
                self = remote.stage == .received ? .onMac : .queued
            }
        case .transcribing:
            let counts = SyncBadge.chunkCounts(in: remote.detail)
            self = .transcribing(done: counts?.done, total: counts?.total, fraction: remote.progress)
        case .transcribed:
            self = .transcribed
        case .failed:
            if let parts = recording.partialTranscript {
                self = .partial(done: parts.partsDone, total: parts.partsTotal)
            } else {
                self = .failed(reason: remote.detail)
            }
        }
    }

    /// Sentence case, the user's terms ("your Mac"), numbers after a dot.
    var label: String {
        switch self {
        case .recording: return "Recording"
        case .onPhone: return "On this iPhone"
        case .waitingForMac: return "Waiting for your Mac"
        case let .uploading(fraction): return "Sending · \(Int((fraction * 100).rounded(.down)))%"
        case .sendFailed: return "Couldn't send"
        case .onMac: return "On your Mac"
        case .queued: return "Queued on your Mac"
        case .retryingOnMac: return "Trying again on your Mac"
        case let .transcribing(done, total, fraction):
            if let done, let total, total > 1 { return "Transcribing · \(done) of \(total)" }
            if let fraction, fraction > 0 { return "Transcribing · \(Int((fraction * 100).rounded(.down)))%" }
            return "Transcribing"
        case .transcribed: return "Transcribed"
        case .partial: return "Partly transcribed"
        case .failed: return "Couldn't transcribe"
        case .damaged: return "Recording damaged"
        }
    }

    var systemImage: String? {
        switch self {
        case .transcribed: return "checkmark"
        case .failed, .sendFailed, .damaged: return "exclamationmark"
        case .uploading: return "arrow.up"
        default: return nil
        }
    }

    var tone: Tone {
        switch self {
        case .recording: return .recording
        case .onPhone, .waitingForMac: return .neutral
        case .uploading, .transcribing: return .active
        case .onMac, .queued, .retryingOnMac, .partial: return .info
        case .transcribed: return .ok
        case .failed, .sendFailed, .damaged: return .error
        }
    }

    /// Whether the dot should pulse (live work in progress).
    var isLive: Bool {
        switch self {
        case .recording, .uploading, .transcribing: return true
        default: return false
        }
    }

    /// The Mac gave up with some parts transcribed, and they are shown.
    var isPartial: Bool {
        if case .partial = self { return true }
        return false
    }

    /// Retry can do something about it: send it again, or ask the Mac to try
    /// transcribing it once more.
    var canRetry: Bool {
        switch self {
        case .sendFailed, .failed, .partial: return true
        default: return false
        }
    }

    var accessibilityLabel: String {
        switch self {
        case let .sendFailed(reason?): return "Couldn't send: \(reason)"
        case let .failed(reason?): return "Couldn't transcribe: \(reason)"
        case let .retryingOnMac(reason?, _, _): return "Trying again on your Mac after a problem: \(reason)"
        case let .partial(done?, total?) where total > 0: return "Partly transcribed: \(done) of \(total) parts"
        case .transcribed: return "Transcribed"
        default: return label
        }
    }

    /// The detail screen's one sentence about where the recording is.
    /// - Parameters:
    ///   - waitingLine: what to say while it waits to be sent (it depends on
    ///     the link to the Mac: `SyncManager.waitingLine`).
    ///   - engineAvailable: from the Mac's `welcome`.
    ///   - fetched: when the transcript arrived, already phrased ("2 min ago").
    func sentence(macName mac: String, waitingLine: String, engineAvailable: Bool?, fetched: String?) -> String {
        switch self {
        case .recording: return "Recording now."
        case .damaged: return "This recording was cut off and can't be sent."
        case .onPhone: return "On this iPhone. Pair your Mac to have it transcribed."
        case .waitingForMac: return waitingLine
        case let .uploading(fraction): return "Sending to \(mac) · \(Int(fraction * 100))%"
        case let .sendFailed(reason): return reason ?? "Couldn't send this recording."
        case .onMac:
            return engineAvailable == false
                ? "On \(mac). It's transcribed once Huske's engine is set up there."
                : "On \(mac), about to be transcribed."
        case .queued: return "On \(mac), next in line to be transcribed."
        case let .retryingOnMac(reason, attempt, maxAttempts):
            var line = "\(mac) hit a problem with it and will try again"
            if let attempt, let maxAttempts, maxAttempts > 1, (1...maxAttempts).contains(attempt) {
                line += " (attempt \(attempt) of \(maxAttempts))"
            }
            return line + (reason.map { ": \($0)" } ?? ".")
        case let .transcribing(done, total, _):
            if let done, let total, total > 1 { return "\(mac) is transcribing it · \(done) of \(total)" }
            return "\(mac) is transcribing it."
        case .transcribed:
            if let fetched { return "Transcribed on \(mac) · \(fetched)" }
            return "Transcribed on \(mac)"
        case let .partial(done, total):
            if let done, let total, total > 0, done <= total {
                return "Part of this recording couldn't be transcribed — \(done) of \(total) parts are below."
            }
            return "Part of this recording couldn't be transcribed — what \(mac) got is below."
        case let .failed(reason):
            return "\(mac) couldn't transcribe it" + (reason.map { ": \($0)" } ?? ".")
        }
    }

    /// What the Mac reports while it means to try again by itself — "Will
    /// retry after an error: decode failed", "Will retry: engine busy" — is
    /// still "queued" or "received" on the wire. Returns the reason ("" when
    /// it gave none), or nil when the detail says no such thing.
    static func retryReason(in detail: String?) -> String? {
        guard let detail, detail.lowercased().hasPrefix("will retry") else { return nil }
        guard let colon = detail.firstIndex(of: ":") else { return "" }
        return detail[detail.index(after: colon)...].trimmingCharacters(in: .whitespaces)
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
