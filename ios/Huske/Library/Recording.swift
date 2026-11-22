// One recording in the iPhone library. Persisted as JSON by `LibraryStore`.
//
// The model deliberately does not import HuskeSync: the Mac-side state is kept
// as a small local snapshot (`RemoteSnapshot`) so the stored library format is
// ours and survives library changes. `SyncManager` converts at the boundary.

import Foundation

struct Recording: Codable, Identifiable, Hashable, Sendable {
    /// UUID string; also the sync protocol's recording ID and the audio file stem.
    let id: String
    var title: String
    let startedAt: Date
    /// Seconds of audio. Live-updated while recording, measured from the file
    /// when it is saved.
    var duration: TimeInterval
    /// Audio file name inside `LibraryStore.audioDirectory`.
    let fileName: String
    var byteCount: Int64
    /// IANA identifier of the zone the recording was made in.
    let timeZoneID: String
    /// The input the recording started on ("iPhone Microphone", "AirPods Pro").
    var inputName: String?
    var capture: CaptureState
    var sync: SyncRecord
    var transcript: TranscriptRecord?
    /// What the Mac could transcribe of a recording it gave up on. Kept apart
    /// from `transcript`, which everything else reads as "transcribed": a
    /// recording with only this is still a failure Retry can fix. Cleared
    /// when the whole transcript arrives.
    var partialTranscript: PartialTranscript?
    /// A short honest note shown on the detail screen (e.g. recovered after a crash).
    var note: String?

    init(id: String, title: String, startedAt: Date, duration: TimeInterval = 0,
         fileName: String, byteCount: Int64 = 0, timeZoneID: String = TimeZone.current.identifier,
         inputName: String? = nil, capture: CaptureState = .inProgress,
         sync: SyncRecord = SyncRecord(), transcript: TranscriptRecord? = nil, note: String? = nil) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.duration = duration
        self.fileName = fileName
        self.byteCount = byteCount
        self.timeZoneID = timeZoneID
        self.inputName = inputName
        self.capture = capture
        self.sync = sync
        self.transcript = transcript
        self.note = note
    }
}

enum CaptureState: String, Codable, Sendable {
    /// The recorder is (or was, if the app died) writing this file.
    case inProgress
    /// Saved and playable; eligible for sync.
    case complete
    /// The app died mid-recording and the file could not be recovered.
    case damaged
}

/// Where this recording is in the phone → Mac pipeline.
struct SyncRecord: Codable, Hashable, Sendable {
    /// The Mac that holds (or held) this recording. A different paired Mac
    /// means it must be uploaded again.
    var macID: String?
    /// Set when the Mac committed (verified) the upload.
    var uploadedAt: Date?
    /// Last state the Mac reported.
    var remote: RemoteSnapshot?
    /// A per-recording failure that retrying will not fix by itself
    /// (e.g. the Mac rejected the file). Cleared by "Retry".
    var failure: String?
    var attempts: Int = 0
    var lastAttemptAt: Date?

    init(macID: String? = nil, uploadedAt: Date? = nil, remote: RemoteSnapshot? = nil,
         failure: String? = nil, attempts: Int = 0, lastAttemptAt: Date? = nil) {
        self.macID = macID
        self.uploadedAt = uploadedAt
        self.remote = remote
        self.failure = failure
        self.attempts = attempts
        self.lastAttemptAt = lastAttemptAt
    }
}

/// Mirror of the protocol's `RemoteState` (sync-protocol.md), stored locally.
enum RemoteStage: String, Codable, Sendable, CaseIterable {
    case unknown, receiving, received, queued, transcribing, transcribed, failed

    var isTerminal: Bool { self == .transcribed || self == .failed }

    /// Unknown future states decode as `.unknown` instead of failing the library.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RemoteStage(rawValue: raw) ?? .unknown
    }
}

struct RemoteSnapshot: Codable, Hashable, Sendable {
    var stage: RemoteStage
    var detail: String?
    var progress: Double?
    var updatedAt: Date
    // Optional extras a Mac sends once both sides announced them
    // (sync-protocol.md § RemoteStatus). nil from an older Mac, and in
    // libraries saved before they existed.
    /// The Mac gave up, but has some parts transcribed to hand over.
    var partial: Bool?
    var partsDone: Int?
    var partsTotal: Int?
    /// The Mac hit an error and will try again by itself.
    var retrying: Bool?
    /// The try that comes next, and how many the Mac makes.
    var attempt: Int?
    var maxAttempts: Int?
}

struct TranscriptRecord: Codable, Hashable, Sendable {
    /// Markdown from the Mac (frontmatter stripped). Nil when the Mac
    /// transcribed the recording but found no speech.
    var markdown: String?
    var fetchedAt: Date
}

/// The parts of a recording the Mac did transcribe before giving up on it.
struct PartialTranscript: Codable, Hashable, Sendable {
    /// Markdown of the finished parts, in order (frontmatter stripped).
    var markdown: String
    /// How many of the recording's parts this is, when the Mac said.
    var partsDone: Int?
    var partsTotal: Int?
    var fetchedAt: Date

    /// Shown above these parts once they are no longer the latest word on
    /// the recording (the Mac is trying again).
    var earlierTryNote: String {
        if let done = partsDone, let total = partsTotal, total > 0, done <= total {
            return "\(done) of \(total) parts, from the earlier try."
        }
        return "Part of the recording, from the earlier try."
    }
}

// MARK: - pipeline predicates (used by SyncManager and the badge)

extension Recording {
    var isTranscriptAvailable: Bool { transcript?.markdown?.isEmpty == false }

    /// Ready to send to `macID`: saved, not yet committed there, no sticky failure.
    func needsUpload(to macID: String) -> Bool {
        guard capture == .complete, sync.failure == nil else { return false }
        if transcript != nil { return false }
        return sync.macID != macID || sync.uploadedAt == nil
    }

    /// Uploaded to `macID` and the Mac has not reached a terminal state yet.
    func awaitsRemote(on macID: String) -> Bool {
        guard capture == .complete, sync.macID == macID, sync.uploadedAt != nil,
              transcript == nil else { return false }
        return !(sync.remote?.stage.isTerminal ?? false)
    }

    /// Sent to `macID`, which gave up on it. Final as far as polling goes,
    /// but the Mac may be asked once more: it can be tried again there.
    func wasGivenUpOn(by macID: String) -> Bool {
        capture == .complete && sync.macID == macID && sync.uploadedAt != nil
            && transcript == nil && sync.remote?.stage == .failed
    }

    /// The Mac has something to read that has not been fetched yet: the
    /// transcript of a recording it finished, or the finished parts of one it
    /// gave up on.
    func needsTranscript(from macID: String) -> Bool {
        guard sync.macID == macID, transcript == nil else { return false }
        return sync.remote?.stage == .transcribed || needsPartialTranscript
    }

    /// The Mac gave up and offers the parts it transcribed, and this iPhone
    /// does not hold those parts yet (none, or fewer than the Mac has now —
    /// a retry that failed again may have got further).
    var needsPartialTranscript: Bool {
        guard transcript == nil, let remote = sync.remote, remote.stage == .failed, remote.partial == true
        else { return false }
        guard let held = partialTranscript else { return true }
        return held.partsDone != remote.partsDone || held.partsTotal != remote.partsTotal
    }

    /// Stores what `transcript` brought back for this recording (nil: the Mac
    /// had nothing to give).
    mutating func storeFetchedTranscript(_ markdown: String?, isPartial: Bool, at date: Date = Date()) {
        guard let markdown else {
            if sync.remote?.stage == .transcribed {
                // Transcribed, and nothing to read: no speech.
                transcript = TranscriptRecord(markdown: nil, fetchedAt: date)
                partialTranscript = nil
            } else {
                // The parts are no longer on offer (the Mac is trying again,
                // or they are gone): stop asking. What was fetched before
                // stays until something better arrives.
                sync.remote?.partial = nil
            }
            return
        }
        if isPartial {
            partialTranscript = PartialTranscript(
                markdown: markdown, partsDone: sync.remote?.partsDone, partsTotal: sync.remote?.partsTotal,
                fetchedAt: date)
            return
        }
        transcript = TranscriptRecord(markdown: markdown, fetchedAt: date)
        partialTranscript = nil
        if sync.remote?.stage == .failed {
            // Asked for the parts and got the whole thing: the Mac finished
            // it meanwhile (it was retried there).
            sync.remote?.stage = .transcribed
            sync.remote?.detail = nil
            sync.remote?.partial = nil
            sync.remote?.partsDone = nil
            sync.remote?.partsTotal = nil
        }
    }
}
