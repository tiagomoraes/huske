// Moves finished recordings to the paired Mac and brings transcripts back.
//
// One run = connect → upload pending recordings one at a time, oldest first →
// poll `status` for uploaded ones until terminal → fetch each transcript once.
// Runs are serialized; a trigger during a run just asks for another pass.
//
// Triggers: a recording was saved, the Mac appeared on Bonjour, the app became
// active, "Sync now", pairing, and BGTaskScheduler tasks. A recording still
// being recorded is never uploaded (only `.complete` captures qualify).

import Foundation
import HuskeSync
import Observation
import OSLog
import UIKit

private let log = Logger(subsystem: "cloud.tiagomoraes.huske.ios", category: "sync")

@MainActor
@Observable
final class SyncManager {
    enum Activity: Equatable {
        case idle
        case connecting
        case uploading(recordingID: String, fraction: Double)
        case checking
    }

    enum Trigger: String {
        case recordingSaved, macAppeared, appActive, manual, pairing, background, retry
    }

    // MARK: observable state

    private(set) var pairedMac: PairedMac?
    private(set) var isMacReachable = false
    private(set) var activity: Activity = .idle
    private(set) var lastSyncAt: Date?
    /// The latest connection-level problem, phrased for people. Cleared by
    /// the next successful contact.
    private(set) var lastError: String?
    /// From `welcome`: whether the Mac has a transcription engine set up.
    private(set) var engineAvailable: Bool?
    /// True once the Mac answered `hello` for this pairing (the pending slot
    /// on the Mac is now a paired device).
    private(set) var hasConfirmedPairing = false

    /// The name this iPhone reports to the Mac.
    var deviceName: String {
        didSet { defaults.set(deviceName, forKey: Keys.deviceName) }
    }

    var isPaired: Bool { pairedMac != nil }
    var isRunning: Bool { runTask != nil }
    var macName: String { pairedMac?.macName ?? "your Mac" }

    /// Live upload fraction for the recording being sent right now.
    func uploadFraction(for recordingID: String) -> Double? {
        if case let .uploading(id, fraction) = activity, id == recordingID { return fraction }
        return nil
    }

    func badge(for recording: Recording) -> SyncBadge {
        SyncBadge(recording: recording, isPaired: isPaired, uploadFraction: uploadFraction(for: recording.id))
    }

    /// Recordings waiting to go to the Mac (for the Mac screen).
    var pendingUploadCount: Int {
        guard let macID = pairedMac?.macID else { return 0 }
        return library.recordings.filter { $0.needsUpload(to: macID) }.count
    }

    // MARK: dependencies

    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let pairingStore: PairingStoring
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let makeConnector: (PairedMac, String) -> any MacConnecting
    @ObservationIgnored private let makePresence: (PairedMac) -> (any PresenceSource)?
    @ObservationIgnored private var presence: (any PresenceSource)?
    @ObservationIgnored private var presenceTask: Task<Void, Never>?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var rerunRequested = false
    @ObservationIgnored private var isForeground = true
    @ObservationIgnored private var backgroundPollingDeadline = Date.distantPast
    @ObservationIgnored private var lastProgressPush = Date.distantPast
    #if DEBUG
    /// Demo mode: never touch the network; states are set by DemoData.
    @ObservationIgnored var isFrozenForDemo = false
    #endif

    private enum Keys {
        static let deviceName = "sync.deviceName"
        static let lastSyncAt = "sync.lastSyncAt"
        static let confirmedMacID = "sync.confirmedMacID"
    }

    init(library: LibraryStore,
         pairingStore: PairingStoring,
         defaults: UserDefaults = .standard,
         defaultDeviceName: String,
         makeConnector: @escaping (PairedMac, String) -> any MacConnecting = { HuskeSyncConnector(pairing: $0, deviceName: $1) },
         makePresence: @escaping (PairedMac) -> (any PresenceSource)? = { MacPresenceMonitor(macID: $0.macID) }) {
        self.library = library
        self.pairingStore = pairingStore
        self.defaults = defaults
        self.makeConnector = makeConnector
        self.makePresence = makePresence
        deviceName = defaults.string(forKey: Keys.deviceName) ?? defaultDeviceName
        lastSyncAt = defaults.object(forKey: Keys.lastSyncAt) as? Date
        pairedMac = pairingStore.load()
        if let mac = pairedMac {
            hasConfirmedPairing = defaults.string(forKey: Keys.confirmedMacID) == mac.macID
            startPresence(for: mac)
        }
    }

    // MARK: triggers

    /// Kicks off a sync pass (or queues another pass if one is running).
    @discardableResult
    func syncNow(_ trigger: Trigger) -> Task<Void, Never>? {
        guard pairedMac != nil else { return nil }
        #if DEBUG
        if isFrozenForDemo { return nil }
        #endif
        if trigger == .manual || trigger == .retry { lastError = nil }
        if let runTask {
            rerunRequested = true
            return runTask
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runWithBackgroundTime(trigger)
            self.runTask = nil
            if self.rerunRequested {
                self.rerunRequested = false
                self.syncNow(.retry)
            }
        }
        runTask = task
        return task
    }

    /// A recording just stopped: send it right away, with background time so
    /// leaving the app (or locking) doesn't cut the upload short.
    func recordingSaved(_ recordingID: String) {
        guard pairedMac != nil else { return }
        syncNow(.recordingSaved)
        scheduleBackgroundSyncIfNeeded()
    }

    func scenePhaseChanged(isActive: Bool) {
        isForeground = isActive
        if isActive {
            syncNow(.appActive)
        } else {
            backgroundPollingDeadline = Date().addingTimeInterval(20)
            scheduleBackgroundSyncIfNeeded()
        }
    }

    /// Clears a recording's failure (or asks the Mac again about a remote
    /// failure) and syncs.
    func retry(_ recordingID: String) {
        library.update(recordingID) { recording in
            recording.sync.failure = nil
            recording.sync.attempts = 0
            if recording.sync.remote?.stage == .failed { recording.sync.remote = nil }
        }
        syncNow(.retry)
    }

    /// Runs one pass for a BGTask; returns when done or cancelled.
    func runBackgroundPass() async {
        backgroundPollingDeadline = Date().addingTimeInterval(20)
        await syncNow(.background)?.value
    }

    func cancelRun() {
        runTask?.cancel()
    }

    // MARK: pairing

    enum PairingResult: Equatable {
        case paired
        case savedButNotReached(String)
        case failed(String)
    }

    func pair(with invite: PairingInvite) async -> PairingResult {
        runTask?.cancel()
        await runTask?.value
        let mac = PairedMac(invite: invite)
        do {
            try pairingStore.save(mac)
        } catch {
            return .failed(error.localizedDescription)
        }
        if let previous = pairedMac, previous.macID != mac.macID {
            // A different Mac: everything not yet transcribed goes to the new one.
            library.updateAll(where: { $0.transcript == nil && $0.sync.macID != nil }) { recording in
                recording.sync = SyncRecord()
            }
        }
        stopPresence()
        pairedMac = mac
        hasConfirmedPairing = false
        defaults.removeObject(forKey: Keys.confirmedMacID)
        engineAvailable = nil
        lastError = nil
        startPresence(for: mac)
        // First contact promotes the Mac's pending slot to a paired device.
        await syncNow(.pairing)?.value
        if hasConfirmedPairing { return .paired }
        return .savedButNotReached(lastError ?? "Waiting for \(mac.macName) — open Huske on your Mac.")
    }

    func forgetMac() {
        runTask?.cancel()
        stopPresence()
        pairingStore.clear()
        pairedMac = nil
        hasConfirmedPairing = false
        defaults.removeObject(forKey: Keys.confirmedMacID)
        isMacReachable = false
        engineAvailable = nil
        lastError = nil
        activity = .idle
    }

    // MARK: presence

    private func startPresence(for mac: PairedMac) {
        guard let monitor = makePresence(mac) else { return }
        presence = monitor
        monitor.start()
        presenceTask = Task { @MainActor [weak self] in
            for await reachable in monitor.updates {
                guard let self, !Task.isCancelled else { return }
                let appeared = reachable && !self.isMacReachable
                self.isMacReachable = reachable
                if appeared { self.syncNow(.macAppeared) }
            }
        }
    }

    private func stopPresence() {
        presenceTask?.cancel()
        presenceTask = nil
        presence?.stop()
        presence = nil
        isMacReachable = false
    }

    // MARK: the run

    private func hasWork(for macID: String) -> Bool {
        library.recordings.contains {
            $0.needsUpload(to: macID) || $0.awaitsRemote(on: macID) || $0.needsTranscript(from: macID)
        }
    }

    private func runWithBackgroundTime(_ trigger: Trigger) async {
        var taskID = UIBackgroundTaskIdentifier.invalid
        taskID = UIApplication.shared.beginBackgroundTask(withName: "huske.sync") { [weak self] in
            MainActor.assumeIsolated {
                self?.runTask?.cancel()
                if taskID != .invalid {
                    UIApplication.shared.endBackgroundTask(taskID)
                    taskID = .invalid
                }
            }
        }
        await run(trigger)
        if taskID != .invalid {
            UIApplication.shared.endBackgroundTask(taskID)
            taskID = .invalid
        }
    }

    private func run(_ trigger: Trigger) async {
        guard let mac = pairedMac else { return }
        let macID = mac.macID
        let mustContact = !hasConfirmedPairing || trigger == .manual || trigger == .pairing
        guard mustContact || hasWork(for: macID) else { return }

        activity = .connecting
        log.info("sync run (\(trigger.rawValue, privacy: .public)) connecting to \(mac.macName, privacy: .public)")
        let session: any MacSession
        do {
            session = try await makeConnector(mac, deviceName).connect(timeout: 8)
        } catch {
            log.error("connect failed: \(String(describing: error), privacy: .public)")
            activity = .idle
            if let text = SyncMessages.text(for: error, macName: mac.macName) { lastError = text }
            scheduleBackgroundSyncIfNeeded()
            return
        }
        didConnect(session.welcome, macID: macID)
        log.info("connected: \(session.welcome.macName, privacy: .public) engine=\(session.welcome.engineAvailable)")

        do {
            try await drive(session, macID: macID)
            lastSyncAt = Date()
            defaults.set(lastSyncAt, forKey: Keys.lastSyncAt)
            lastError = nil
        } catch {
            log.error("sync run ended: \(String(describing: error), privacy: .public)")
            if let text = SyncMessages.text(for: error, macName: macName) { lastError = text }
        }
        await session.close()
        activity = .idle
        scheduleBackgroundSyncIfNeeded()
    }

    private func didConnect(_ welcome: Welcome, macID: String) {
        hasConfirmedPairing = true
        defaults.set(macID, forKey: Keys.confirmedMacID)
        engineAvailable = welcome.engineAvailable
        lastError = nil
        if var mac = pairedMac, mac.macID == macID, mac.macName != welcome.macName, !welcome.macName.isEmpty {
            mac.macName = welcome.macName
            try? pairingStore.save(mac)
            pairedMac = mac
        }
    }

    private func drive(_ session: any MacSession, macID: String) async throws {
        var pollDelay: Double = 2
        var checksumRetries: [String: Int] = [:]

        while true {
            try Task.checkCancellation()
            guard pairedMac?.macID == macID else { return }

            // 1. Uploads, one at a time, oldest first.
            if let next = library.recordings
                .filter({ $0.needsUpload(to: macID) })
                .min(by: { $0.startedAt < $1.startedAt }) {
                do {
                    try await upload(next, over: session, macID: macID)
                } catch let error as SyncError where error == .checksumMismatch {
                    let count = checksumRetries[next.id, default: 0] + 1
                    checksumRetries[next.id] = count
                    if count >= 2 {
                        markFailed(next.id, "The upload didn't verify on \(macName) twice. The file may be damaged.")
                    }
                } catch where SyncMessages.isPerRecording(error) {
                    markFailed(next.id, SyncMessages.text(for: error, macName: macName) ?? "Upload failed.")
                }
                activity = .connecting
                continue
            }

            // 2. Transcripts that are ready.
            for recording in library.recordings where recording.needsTranscript(from: macID) {
                try Task.checkCancellation()
                let markdown = try await session.transcript(recording.id)
                log.info("transcript for \(recording.id, privacy: .public): \(markdown?.count ?? 0) chars")
                library.update(recording.id) {
                    $0.transcript = TranscriptRecord(markdown: markdown, fetchedAt: Date())
                }
            }

            // 3. Poll the Mac until everything uploaded is terminal.
            let waiting = library.recordings.filter { $0.awaitsRemote(on: macID) }
            guard !waiting.isEmpty, shouldKeepPolling else { return }
            activity = .checking
            let statuses = try await session.status(waiting.map(\.id))
            let readyBefore = library.recordings.filter { $0.needsTranscript(from: macID) }.count
            apply(statuses, macID: macID)
            let readyAfter = library.recordings.filter { $0.needsTranscript(from: macID) }.count
            if readyAfter > readyBefore || library.recordings.contains(where: { $0.needsUpload(to: macID) }) {
                pollDelay = 2
                continue
            }
            try await Task.sleep(for: .seconds(pollDelay))
            pollDelay = min(pollDelay * 1.5, 10)
        }
    }

    private var shouldKeepPolling: Bool {
        isForeground || Date() < backgroundPollingDeadline
    }

    private func upload(_ recording: Recording, over session: any MacSession, macID: String) async throws {
        let fileURL = library.audioURL(for: recording)
        let device = deviceName
        let zone = TimeZone(identifier: recording.timeZoneID) ?? .current
        library.update(recording.id) {
            $0.sync.attempts += 1
            $0.sync.lastAttemptAt = Date()
        }
        activity = .uploading(recordingID: recording.id, fraction: 0)

        // Hashing reads the whole file: keep it off the main actor.
        let manifest = try await Task.detached(priority: .userInitiated) {
            try RecordingManifest.make(
                id: recording.id, title: recording.title, startedAt: recording.startedAt,
                durationSeconds: recording.duration, fileURL: fileURL,
                sampleRate: RecorderController.sampleRate, channels: RecorderController.channels,
                timeZone: zone, deviceName: device)
        }.value

        let id = recording.id
        let status = try await session.upload(manifest: manifest, fileURL: fileURL) { [weak self] sent, total in
            Task { @MainActor in self?.reportProgress(id, sent: sent, total: total) }
        }
        log.info("uploaded \(id, privacy: .public): \(status.state.rawValue, privacy: .public)")
        library.update(id) {
            $0.sync.macID = macID
            $0.sync.uploadedAt = Date()
            $0.sync.failure = nil
            $0.sync.remote = RemoteSnapshot(status)
        }
    }

    private func reportProgress(_ id: String, sent: Int64, total: Int64) {
        guard case let .uploading(current, previous) = activity, current == id, total > 0 else { return }
        let fraction = Double(sent) / Double(total)
        let now = Date()
        // Coalesce: ~10 Hz is plenty for a badge.
        guard fraction >= 1 || fraction - previous >= 0.01 || now.timeIntervalSince(lastProgressPush) > 0.1
        else { return }
        lastProgressPush = now
        activity = .uploading(recordingID: id, fraction: fraction)
    }

    private func apply(_ statuses: [RemoteStatus], macID: String) {
        for status in statuses {
            library.update(status.recordingID) { recording in
                guard recording.sync.macID == macID else { return }
                if status.state == .unknown {
                    // The Mac no longer knows it (reset, pruned): send again.
                    recording.sync.uploadedAt = nil
                    recording.sync.remote = nil
                } else {
                    recording.sync.remote = RemoteSnapshot(status)
                }
            }
        }
    }

    private func markFailed(_ id: String, _ message: String) {
        library.update(id) { $0.sync.failure = message }
    }

    private func scheduleBackgroundSyncIfNeeded() {
        guard let macID = pairedMac?.macID, hasWork(for: macID) else { return }
        BackgroundSync.schedule()
    }
}

#if DEBUG
extension SyncManager {
    func setDemoState(reachable: Bool, activity: Activity, lastSyncAt: Date?, engineAvailable: Bool?) {
        isMacReachable = reachable
        self.activity = activity
        self.lastSyncAt = lastSyncAt
        self.engineAvailable = engineAvailable
        hasConfirmedPairing = true
    }
}
#endif

extension RemoteSnapshot {
    init(_ status: RemoteStatus) {
        self.init(
            stage: RemoteStage(rawValue: status.state.rawValue) ?? .unknown,
            detail: status.detail,
            progress: status.progress,
            updatedAt: status.updatedAt)
    }
}
