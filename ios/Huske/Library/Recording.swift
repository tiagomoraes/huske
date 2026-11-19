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
}

struct TranscriptRecord: Codable, Hashable, Sendable {
    /// Markdown from the Mac (frontmatter stripped). Nil when the Mac
    /// transcribed the recording but found no speech.
    var markdown: String?
    var fetchedAt: Date
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

    /// The Mac finished it but the transcript has not been fetched yet.
    func needsTranscript(from macID: String) -> Bool {
        sync.macID == macID && sync.remote?.stage == .transcribed && transcript == nil
    }
}
