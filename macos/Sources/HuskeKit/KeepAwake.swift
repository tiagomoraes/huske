// Keeps the Mac from idle-sleeping while a phone recording is in flight:
// being received, or being handed to the engine. Nothing else — an idle Huske
// never holds the Mac awake, and it does not fight a closed lid.
//
// Every reason is a lease with a deadline, renewed by news (a chunk arriving)
// and dropped when the work ends. A phone that walks away mid-upload, a
// hand-off that never answers: the lease runs out by itself, so a bug or a
// lost event cannot pin the Mac awake.

import Foundation
import HuskeSync

@MainActor
public final class KeepAwake {
    public typealias Begin = @Sendable (_ reason: String) -> AnyObject
    public typealias End = @Sendable (_ token: AnyObject) -> Void

    /// A chunk arrives every few milliseconds; this long without one and the
    /// upload is not "being received" any more.
    public static let uploadLease: TimeInterval = 45
    /// `huske inbox add` is given 300 s before it is killed.
    public static let handOffLease: TimeInterval = 330
    /// `huske inbox process` is given 6 h; one more minute to notice it ended.
    public static let processLease: TimeInterval = 6 * 3600 + 60

    private let reason: String
    private let begin: Begin
    private let activity: Activity
    private let now: () -> Date
    private var leases: [String: Date] = [:]
    /// Which phone each upload came from, to drop them when it disconnects.
    private var uploadDevice: [String: String] = [:]
    private var sweeper: Task<Void, Never>?

    /// Owns the system activity, and ends it when it goes away — whatever
    /// happens to the object that asked for it.
    private final class Activity: @unchecked Sendable {
        private let end: End
        private let lock = NSLock()
        private var token: AnyObject?

        init(end: @escaping End) { self.end = end }

        var isActive: Bool { lock.withLock { token != nil } }

        func start(_ token: AnyObject) {
            lock.withLock { self.token = token }
        }

        func finish() {
            let held: AnyObject? = lock.withLock {
                defer { token = nil }
                return token
            }
            if let held { end(held) }
        }

        deinit { finish() }
    }

    /// `begin`/`end` default to `ProcessInfo`'s idle-sleep activity; tests
    /// pass their own to count them.
    public init(
        reason: String = "Receiving recordings from iPhone",
        begin: Begin? = nil, end: End? = nil, now: @escaping () -> Date = { Date() }
    ) {
        self.reason = reason
        self.begin = begin ?? { reason in
            ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: reason)
        }
        self.activity = Activity(
            end: end ?? { token in
                if let activity = token as? NSObjectProtocol { ProcessInfo.processInfo.endActivity(activity) }
            })
        self.now = now
    }

    deinit {
        sweeper?.cancel()
    }

    public var isHolding: Bool { activity.isActive }
    public var reasons: Set<String> { Set(leases.keys) }

    /// Hold — or keep holding — for `key`, for at most `lease` from now.
    public func hold(_ key: String, for lease: TimeInterval) {
        leases[key] = now().addingTimeInterval(lease)
        update()
    }

    public func release(_ key: String) {
        guard leases.removeValue(forKey: key) != nil else { return }
        uploadDevice.removeValue(forKey: Self.uploadID(key) ?? "")
        update()
    }

    public func releaseAll() {
        leases.removeAll()
        uploadDevice.removeAll()
        update()
    }

    /// Drops leases past their deadline. Runs by itself while anything is
    /// held; public so a test can drive the clock.
    public func sweep() {
        let moment = now()
        let expired = leases.filter { $0.value <= moment }.map(\.key)
        for key in expired {
            leases.removeValue(forKey: key)
            uploadDevice.removeValue(forKey: Self.uploadID(key) ?? "")
        }
        update()
    }

    // MARK: uploads, from the server's events

    /// Held from the offer, renewed by every chunk, dropped on commit, on a
    /// failed checksum, and when the phone that was sending disconnects.
    public func note(_ event: SyncServerEvent) {
        switch event {
        case .uploadStarted(let manifest, _, let deviceID):
            uploadDevice[manifest.id] = deviceID
            hold(Self.uploadKey(manifest.id), for: Self.uploadLease)
        case .uploadProgress(let id, _, _):
            hold(Self.uploadKey(id), for: Self.uploadLease)
        case .uploadVerified(let manifest, _):
            release(Self.uploadKey(manifest.id))
        case .uploadFailed(let id, _):
            release(Self.uploadKey(id))
        case .deviceDisconnected(let deviceID):
            for (id, device) in uploadDevice where device == deviceID {
                release(Self.uploadKey(id))
            }
        default:
            break
        }
    }

    public static func uploadKey(_ recordingID: String) -> String { "upload:\(recordingID)" }
    public static func handOffKey(_ recordingID: String) -> String { "handoff:\(recordingID)" }
    public static let processKey = "inbox-process"

    private static func uploadID(_ key: String) -> String? {
        key.hasPrefix("upload:") ? String(key.dropFirst("upload:".count)) : nil
    }

    // MARK: the activity

    private func update() {
        if leases.isEmpty {
            sweeper?.cancel()
            sweeper = nil
            activity.finish()
            return
        }
        if !activity.isActive { activity.start(begin(reason)) }
        scheduleSweep()
    }

    /// One sleeping task at a time, woken at the earliest deadline. Renewals
    /// do not reschedule it: it simply finds nothing expired and sleeps on.
    private func scheduleSweep() {
        guard sweeper == nil, let earliest = leases.values.min() else { return }
        let wait = max(0.05, earliest.timeIntervalSince(now()))
        sweeper = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.sweeper = nil
            self.sweep()
        }
    }
}
