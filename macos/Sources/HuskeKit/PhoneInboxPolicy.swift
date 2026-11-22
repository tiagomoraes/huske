// Small decisions the iPhone pane's coordinator makes around the engine
// inbox, kept here so tests can pin them (the coordinator lives in the app
// target, which the tests cannot import).

import Foundation
import HuskeSync

extension PhoneInbox {
    // MARK: answering `commit`

    public static let handingOffDetail = "Handing to the transcriber"
    public static let noEngineDetail = "Waiting for a huske engine that can transcribe phone recordings"

    /// What the phone is told the moment its upload is verified and kept on
    /// this Mac. Always `received`, and at once: the hand-off to the engine
    /// (`huske inbox add`, usually 0.2 s, but a cold Python start can take
    /// longer than the phone's 30 s reply timeout) happens after the answer,
    /// from the durable pending folder. `received` is not terminal, so the
    /// phone keeps asking and sees `queued` a moment later.
    public static func commitAnswer(
        recordingID: String, engineAvailable: Bool, now: Date = .now
    ) -> RemoteStatus {
        RemoteStatus(
            recordingID: recordingID, state: .received,
            detail: engineAvailable ? handingOffDetail : noEngineDetail, updatedAt: now)
    }

    // MARK: a hand-off that did not go through

    /// `detail` of an upload whose `huske inbox add` failed, before the reason.
    /// Phones without `status.retry` recognise the state by this text.
    public static let handOffRetryPrefix = "Will retry: "

    /// The verified upload is safe on this Mac, but the engine did not take
    /// it (`message` says why). The hand-off is tried again every minute, so
    /// this is "will retry", without a count: there is no limit.
    public static func handOffRetryStatus(
        recordingID: String, message: String, now: Date = .now
    ) -> RemoteStatus {
        RemoteStatus(
            recordingID: recordingID, state: .received, detail: "\(handOffRetryPrefix)\(message)",
            updatedAt: now
        ).withRetry()
    }

    /// What the phone is told about an upload still waiting in the pending
    /// folder, given the line the iPhone pane shows for it.
    public static func pendingStatus(recordingID: String, detail: String, now: Date = .now) -> RemoteStatus {
        let status = RemoteStatus(recordingID: recordingID, state: .received, detail: detail, updatedAt: now)
        return detail.hasPrefix(handOffRetryPrefix) ? status.withRetry() : status
    }

    // MARK: pacing `inbox process`

    /// Between passes when nothing is waiting on one in particular.
    public static let idlePassGap: TimeInterval = 120
    /// When an item failed with attempts left: all it needs is another pass.
    /// Waiting out the idle gap each time made a final failure take three and
    /// a half minutes to reach the phone.
    public static let retryPassGap: TimeInterval = 20

    public static func passGap(retryPending: Bool) -> TimeInterval {
        retryPending ? retryPassGap : idlePassGap
    }

    // MARK: Retry from the phone

    /// A phone that offers a `failed` recording again is asking for another
    /// try (sync-protocol.md § Retrying). One request at a time per recording,
    /// and not more often than this — a retry buys the engine three fresh
    /// attempts, and a client that re-offers in a loop must not turn that
    /// into transcribing a broken file for ever.
    public static let reofferRetryCooldown: TimeInterval = 30

    public static func shouldRetryOnReoffer(
        lastRequest: Date?, inFlight: Bool, engineAvailable: Bool, now: Date = .now
    ) -> Bool {
        guard engineAvailable, !inFlight else { return false }
        guard let lastRequest else { return true }
        return now.timeIntervalSince(lastRequest) >= reofferRetryCooldown
    }
}
