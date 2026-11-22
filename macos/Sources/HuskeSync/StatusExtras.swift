// The optional parts of `RemoteStatus` and `transcriptReply`, and the
// capabilities that gate them (sync-protocol.md § Versioning and
// capabilities, § RemoteStatus).
//
// Both are additive: a peer that did not announce the capability is sent, and
// uses, exactly what v1 had before them. The Mac's delegate always fills the
// fields in; `limited(to:)` is where they are held back.

import Foundation

extension SyncCapability {
    /// `RemoteStatus.partial` / `partsDone` / `partsTotal`, and `transcript`
    /// answering for a `failed` recording with the parts that were
    /// transcribed (`transcriptReply.partial`).
    public static let partialTranscript = "transcript.partial"
    /// `RemoteStatus.retrying` / `attempt` / `maxAttempts`: "the Mac will try
    /// again by itself" as fields, where older builds read it off `detail`.
    public static let retryState = "status.retry"
}

extension RemoteStatus {
    /// This status, marked as a failure that still has `done` of `total`
    /// parts to show (`transcript.partial`).
    public func withPartialTranscript(done: Int, total: Int) -> RemoteStatus {
        var copy = self
        copy.partial = true
        copy.partsDone = done
        copy.partsTotal = total
        return copy
    }

    /// This status, marked as "the Mac will try again by itself"
    /// (`status.retry`). `attempt` is the try that comes next.
    public func withRetry(attempt: Int? = nil, maxAttempts: Int? = nil) -> RemoteStatus {
        var copy = self
        copy.retrying = true
        copy.attempt = attempt
        copy.maxAttempts = maxAttempts
        return copy
    }

    /// What a connection whose two ends share `capabilities` carries: the
    /// extras of every feature not in the list are dropped, the v1 fields
    /// (`state`, `detail`, `progress`…) are never touched. The Mac applies it
    /// to what it sends, the phone to what it receives.
    public func limited(to capabilities: Set<String>) -> RemoteStatus {
        var copy = self
        if !capabilities.contains(SyncCapability.partialTranscript) {
            copy.partial = nil
            copy.partsDone = nil
            copy.partsTotal = nil
        }
        if !capabilities.contains(SyncCapability.retryState) {
            copy.retrying = nil
            copy.attempt = nil
            copy.maxAttempts = nil
        }
        return copy
    }

    /// The same status with another `detail` (which is immutable): for the
    /// wire clamp, which must not lose the extras.
    func replacingDetail(_ detail: String?) -> RemoteStatus {
        var copy = RemoteStatus(
            recordingID: recordingID, state: state, detail: detail, updatedAt: updatedAt,
            progress: progress)
        copy.partial = partial
        copy.partsDone = partsDone
        copy.partsTotal = partsTotal
        copy.retrying = retrying
        copy.attempt = attempt
        copy.maxAttempts = maxAttempts
        return copy
    }
}

extension SyncSession {
    /// The status extras this session may use: the ones both sides announced.
    var statusExtras: Set<String> {
        Set([SyncCapability.partialTranscript, SyncCapability.retryState].filter(supports))
    }
}

/// What `transcript` brought back.
public struct FetchedTranscript: Sendable, Equatable {
    /// UTF-8 Markdown, frontmatter stripped.
    public let text: String
    /// Only the parts the Mac could transcribe of a recording it gave up on
    /// (`transcript.partial`); false for a finished recording's transcript.
    public let isPartial: Bool

    public init(text: String, isPartial: Bool = false) {
        self.text = text
        self.isPartial = isPartial
    }
}
