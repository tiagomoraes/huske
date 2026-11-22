// Receives recordings from paired iPhones (HuskeSync's SyncServer) and hands
// them to the engine inbox through the CLI — never by writing the inbox
// itself (specs/002-phone-sync/contracts/inbox.md). Reads the engine-owned
// status.json files to answer the phone and to drive the iPhone pane.
//
// Lifecycle: AppModel owns one; `bootstrap()` starts the listener once the
// engine is probed (the setting "Receive recordings from iPhone", default on,
// can turn it off). Nothing happens at init, so the offscreen renderer and
// previews never open sockets or touch Application Support.

import AppKit
import Foundation
import HuskeKit
import HuskeSync
import Observation
import SystemConfiguration
import os

@MainActor
@Observable
final class PhoneSyncCoordinator {
    static let enabledKey = "huskePhoneSyncEnabled"
    /// Recent recordings kept in the pane.
    static let recordingLimit = 50

    /// One phone recording as the pane shows it.
    struct Recording: Identifiable, Equatable, Codable {
        let id: String
        var title: String
        var deviceName: String
        var startedAt: Date
        var durationSeconds: Double
        var byteCount: Int64
        var state: RemoteState
        var progress: Double?
        var detail: String?
        var transcripts: [String]
        var updatedAt: Date

        init(manifest: RecordingManifest, state: RemoteState, progress: Double? = nil) {
            id = manifest.id
            title = manifest.title
            deviceName = manifest.deviceName
            startedAt = manifest.startedAt
            durationSeconds = manifest.durationSeconds
            byteCount = manifest.byteCount
            self.state = state
            self.progress = progress
            detail = nil
            transcripts = []
            updatedAt = Date()
        }

        init(
            id: String, title: String, deviceName: String, startedAt: Date,
            durationSeconds: Double, byteCount: Int64, state: RemoteState,
            progress: Double? = nil, detail: String? = nil, transcripts: [String] = [],
            updatedAt: Date = Date()
        ) {
            self.id = id
            self.title = title
            self.deviceName = deviceName
            self.startedAt = startedAt
            self.durationSeconds = durationSeconds
            self.byteCount = byteCount
            self.state = state
            self.progress = progress
            self.detail = detail
            self.transcripts = transcripts
            self.updatedAt = updatedAt
        }
    }

    // MARK: observable state

    /// "Receive recordings from iPhone".
    var enabled: Bool =
        (UserDefaults.standard.object(forKey: PhoneSyncCoordinator.enabledKey) as? Bool) ?? true
    {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            if enabled { startIfEnabled() } else { stopServer() }
        }
    }

    private(set) var devices: [PairedDevice] = []
    private(set) var recordings: [Recording] = []
    private(set) var isListening = false
    private(set) var listenerError: String?
    let macName: String

    /// The invite on screen in the pairing sheet.
    private(set) var activeInvite: PairingInvite?
    /// Set when the phone holding `activeInvite` says hello.
    private(set) var pairedFromInvite: PairedDevice?
    var pairingSheetVisible = false

    /// Paired (not pending) devices, newest first.
    var pairedDevices: [PairedDevice] {
        devices.filter(\.isPaired).sorted { ($0.pairedAt ?? .distantPast) > ($1.pairedAt ?? .distantPast) }
    }

    /// Recordings still moving (for the menu bar line and the poll cadence).
    var activeRecordings: [Recording] {
        recordings.filter { !$0.state.isTerminal && $0.state != .unknown }
    }

    // MARK: plumbing

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var server: SyncServer?
    @ObservationIgnored private var registry: DeviceRegistry?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var processTask: Task<Void, Never>?
    @ObservationIgnored private var processAgain = false
    @ObservationIgnored private var lastProcessEnded: Date?
    @ObservationIgnored private var handOffInFlight: Set<String> = []
    @ObservationIgnored private var lastHandOffAttempt: Date?
    /// Read from the server's queue (welcome), so it lives outside the actor.
    private nonisolated let engineAvailableFlag = OSAllocatedUnfairLock(initialState: false)
    private let log = Logger(subsystem: "cloud.tiagomoraes.huske", category: "phone-sync")

    init() {
        macName = Self.computerName()
    }

    func attach(model: AppModel) {
        self.model = model
    }

    // MARK: paths

    static func supportDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Huske/PhoneSync", isDirectory: true)
    }

    private var support: URL { Self.supportDirectory() }
    private var stagingDirectory: URL { support.appendingPathComponent("staging", isDirectory: true) }
    /// Verified uploads waiting for an engine that can take them.
    private var pendingDirectory: URL { support.appendingPathComponent("pending", isDirectory: true) }
    private var indexURL: URL { support.appendingPathComponent("recordings.json") }

    private var inboxRoot: URL {
        PhoneInbox.root(fromConfigValue: model?.config.snapshot?.string("inbox_root"))
    }

    // MARK: lifecycle

    /// Idempotent; called from AppModel.bootstrap() after every engine probe.
    func startIfEnabled() {
        refreshEngineAvailability()
        guard enabled, !(model?.isDemo ?? false) else { return }
        if registry == nil {
            try? FileManager.default.createDirectory(
                at: support, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            registry = DeviceRegistry(fileURL: support.appendingPathComponent("devices.json"))
            loadIndex()
        }
        guard server == nil, let registry else {
            retryPendingHandOffs()
            return
        }
        let server = SyncServer(
            registry: registry, stagingDirectory: stagingDirectory, macName: macName,
            serverVersion: model?.appVersion ?? "0.0.0")
        server.delegate = self
        let log = self.log
        server.logHandler = { message in log.info("\(message, privacy: .public)") }
        server.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        do {
            try server.start()
            self.server = server
            listenerError = nil
            // Uploads verified before a quit/crash but never handed off.
            Task { await server.redeliverVerified() }
        } catch {
            listenerError = error.localizedDescription
            return
        }
        reloadDevices()
        startPolling()
        retryPendingHandOffs()
    }

    private func stopServer() {
        server?.stop()
        server = nil
        isListening = false
        pollTask?.cancel()
        pollTask = nil
    }

    func refreshEngineAvailability() {
        let available = engineCanTakeRecordings
        engineAvailableFlag.withLock { $0 = available }
    }

    /// The selected engine has `huske inbox`.
    var engineCanTakeRecordings: Bool {
        guard let model, model.binaryURL != nil, let caps = model.capabilities else { return false }
        return caps.isUsable && caps.inboxCLI
    }

    // MARK: pairing

    func beginPairing() {
        guard let server else { return }
        pairedFromInvite = nil
        activeInvite = server.makeInvite()
        reloadDevices()
        pairingSheetVisible = true
    }

    /// A fresh code after the old one expired (the server prunes the old
    /// slot by itself).
    func renewInvite() {
        beginPairing()
    }

    /// Closing the sheet does not withdraw the invite: "Copy link", close,
    /// paste on the phone is a real flow. An unused slot expires after 10
    /// minutes (sync-protocol.md § Pairing).
    func endPairing() {
        pairingSheetVisible = false
        activeInvite = nil
        pairedFromInvite = nil
        reloadDevices()
    }

    func removeDevice(_ deviceID: String) {
        if let server {
            server.removeDevice(deviceID)
        } else {
            registry?.remove(deviceID: deviceID)
        }
        reloadDevices()
    }

    private func reloadDevices() {
        devices = registry?.devices() ?? []
        if let invite = activeInvite, pairedFromInvite == nil,
            let device = devices.first(where: { $0.deviceID == invite.deviceID }), device.isPaired
        {
            pairedFromInvite = device
        }
    }

    // MARK: server events

    private func handle(_ event: SyncServerEvent) {
        switch event {
        case .listening:
            isListening = true
            listenerError = nil
        case .listenerFailed(let message):
            isListening = false
            listenerError = message
        case .devicePaired, .deviceConnected:
            reloadDevices()
        case .deviceDisconnected:
            break
        case .uploadStarted(let manifest, let offset, _):
            let progress = manifest.byteCount > 0 ? Double(offset) / Double(manifest.byteCount) : 0
            upsert(Recording(manifest: manifest, state: .receiving, progress: progress))
        case .uploadProgress(let id, let received, let total):
            guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
            let progress = total > 0 ? Double(received) / Double(total) : 1
            // Coalesce: a 256 KiB chunk per ack would re-render the list
            // dozens of times a second on a fast link.
            if abs((recordings[index].progress ?? 0) - progress) >= 0.01 || received == total {
                recordings[index].progress = progress
                recordings[index].state = .receiving
            }
        case .uploadFailed(let id, let reason):
            if let index = recordings.firstIndex(where: { $0.id == id }) {
                recordings[index].detail = reason
            }
        case .uploadVerified(let manifest, _):
            var recording = recordings.first { $0.id == manifest.id } ?? Recording(manifest: manifest, state: .received)
            recording.state = .received
            recording.progress = nil
            upsert(recording)
        }
    }

    private func upsert(_ recording: Recording) {
        if let index = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings[index] = recording
        } else {
            recordings.insert(recording, at: 0)
        }
        recordings.sort { $0.startedAt > $1.startedAt }
        if recordings.count > Self.recordingLimit {
            recordings.removeLast(recordings.count - Self.recordingLimit)
        }
        saveIndex()
    }

    // MARK: hand-off to the engine

    private func pendingAudioURL(_ manifest: RecordingManifest) -> URL {
        pendingDirectory.appendingPathComponent("\(manifest.id).\(manifest.fileExtension)")
    }

    private func pendingManifestURL(_ id: String) -> URL {
        pendingDirectory.appendingPathComponent("\(id).json")
    }

    private func pendingManifest(_ id: String) -> RecordingManifest? {
        guard let data = try? Data(contentsOf: pendingManifestURL(id)) else { return nil }
        return try? JSONDecoder.wire.decode(RecordingManifest.self, from: data)
    }

    private func allPendingManifests() -> [RecordingManifest] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: pendingDirectory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }
            .compactMap { pendingManifest(String($0.dropLast(5))) }
    }

    /// Takes a verified upload out of the server's staging area, then tries to
    /// hand it to the engine.
    fileprivate func receive(manifest: RecordingManifest, fileURL: URL) async -> RemoteStatus {
        do {
            try FileManager.default.createDirectory(
                at: pendingDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let destination = pendingAudioURL(manifest)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: fileURL, to: destination)
            try JSONEncoder.wire.encode(manifest).write(to: pendingManifestURL(manifest.id), options: .atomic)
        } catch {
            log.error("could not keep \(manifest.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            // Leave the file where the server put it; it still answers
            // `received` for it and the phone will not re-send.
            return RemoteStatus(recordingID: manifest.id, state: .received, detail: "Saved on the Mac")
        }
        var recording = recordings.first { $0.id == manifest.id } ?? Recording(manifest: manifest, state: .received)
        recording.state = .received
        recording.progress = nil
        recording.detail = engineCanTakeRecordings ? "Handing to the transcriber" : Self.noEngineDetail
        upsert(recording)
        return await handOff(manifest)
    }

    static let noEngineDetail = "Waiting for a huske engine that can transcribe phone recordings"

    /// `huske inbox add … --move`; on success the audio now lives in the inbox.
    private func handOff(_ manifest: RecordingManifest) async -> RemoteStatus {
        let audio = pendingAudioURL(manifest)
        guard engineCanTakeRecordings, let binary = model?.binaryURL else {
            return RemoteStatus(recordingID: manifest.id, state: .received, detail: Self.noEngineDetail)
        }
        guard !handOffInFlight.contains(manifest.id) else {
            return RemoteStatus(recordingID: manifest.id, state: .received, detail: "Handing to the transcriber")
        }
        handOffInFlight.insert(manifest.id)
        defer { handOffInFlight.remove(manifest.id) }
        lastHandOffAttempt = Date()

        // `--move` may already have taken the file on an earlier attempt whose
        // answer we could not read. The inbox is the source of truth.
        if !FileManager.default.fileExists(atPath: audio.path),
            PhoneInbox.readStatus(root: inboxRoot, id: manifest.id) == nil,
            let rescued = PhoneInbox.stagedAudio(root: inboxRoot, id: manifest.id)
        {
            // An `inbox add --move` killed between the move and its final
            // rename left the audio in the engine's staging: take it back.
            try? FileManager.default.moveItem(at: rescued, to: audio)
        }
        if !FileManager.default.fileExists(atPath: audio.path) {
            try? FileManager.default.removeItem(at: pendingManifestURL(manifest.id))
            if let item = PhoneInbox.readStatus(root: inboxRoot, id: manifest.id) {
                let status = PhoneInbox.remoteStatus(for: item)
                apply(status, transcripts: item.transcripts, to: manifest.id)
                scheduleInboxProcess()
                return status
            }
            let status = RemoteStatus(
                recordingID: manifest.id, state: .failed,
                detail: "The audio file is missing on the Mac; record or send it again")
            apply(status, transcripts: [], to: manifest.id)
            return status
        }

        let outcome: PhoneInbox.AddOutcome
        do {
            let result = try await CLIRunner.run(
                binary: binary, arguments: PhoneInbox.addArguments(fileURL: audio, manifest: manifest),
                timeout: 300)
            outcome = PhoneInbox.parseAddOutput(status: result.status, stdout: result.stdout, stderr: result.stderr)
        } catch {
            outcome = .failed(error.localizedDescription)
        }
        switch outcome {
        case .added(let item, _):
            // `--move` moved it; an idempotent re-add leaves our copy behind.
            try? FileManager.default.removeItem(at: audio)
            try? FileManager.default.removeItem(at: pendingManifestURL(manifest.id))
            let status = PhoneInbox.remoteStatus(for: item)
            apply(status, transcripts: item.transcripts, to: manifest.id)
            log.info("handed \(manifest.id, privacy: .public) to the inbox (\(item.rawState, privacy: .public))")
            scheduleInboxProcess()
            return status
        case .failed(let message):
            log.error("inbox add failed for \(manifest.id, privacy: .public): \(message, privacy: .public)")
            let status = RemoteStatus(
                recordingID: manifest.id, state: .received, detail: "Will retry: \(message)")
            apply(status, transcripts: [], to: manifest.id)
            return status
        }
    }

    private func retryPendingHandOffs() {
        guard engineCanTakeRecordings else { return }
        let pending = allPendingManifests()
        guard !pending.isEmpty else { return }
        Task {
            for manifest in pending {
                _ = await self.handOff(manifest)
            }
        }
    }

    /// `huske inbox process` when no live engine is there to pick the item up.
    /// Single-flight; a request while one runs queues exactly one more pass.
    func scheduleInboxProcess() {
        guard engineCanTakeRecordings, let binary = model?.binaryURL else { return }
        if processTask != nil {
            processAgain = true
            return
        }
        if liveEngineRunning() {
            // The live engine scans the inbox every few seconds and holds its
            // lock; a one-shot process would only report "deferred".
            return
        }
        processTask = Task {
            repeat {
                processAgain = false
                log.info("running huske inbox process")
                do {
                    // Transcription takes real time; the watchdog is only a
                    // backstop against a wedged process.
                    let result = try await CLIRunner.run(
                        binary: binary, arguments: ["inbox", "process", "--json"], timeout: 6 * 3600)
                    log.info("inbox process exited \(result.status)")
                } catch {
                    log.error("inbox process failed to launch: \(error.localizedDescription, privacy: .public)")
                }
                await refreshStatuses()
            } while processAgain && !liveEngineRunning()
            processTask = nil
            lastProcessEnded = Date()
        }
    }

    var inboxProcessRunning: Bool { processTask != nil }

    private func liveEngineRunning() -> Bool {
        if model?.session.isBusy == true { return true }
        return SessionDiscovery.findLiveEngineSocket() != nil
    }

    // MARK: status

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshStatuses()
                self.maintenance(tick: ticks)
                ticks += 1
                let busy = !self.activeRecordings.isEmpty
                try? await Task.sleep(nanoseconds: busy ? 2_000_000_000 : 15_000_000_000)
            }
        }
    }

    /// Re-reads status.json for every recording that is still moving.
    func refreshStatuses() async {
        let root = inboxRoot
        let pendingIDs = Set(allPendingManifests().map(\.id))
        for recording in recordings where !recording.state.isTerminal || recording.transcripts.isEmpty {
            if pendingIDs.contains(recording.id) || recording.state == .receiving { continue }
            guard let item = PhoneInbox.readStatus(root: root, id: recording.id) else { continue }
            apply(PhoneInbox.remoteStatus(for: item), transcripts: item.transcripts, to: recording.id)
        }
    }

    private func maintenance(tick: Int) {
        refreshEngineAvailability()
        // Pending uploads: the engine may have been upgraded since.
        if engineCanTakeRecordings, !allPendingManifests().isEmpty,
            Date().timeIntervalSince(lastHandOffAttempt ?? .distantPast) > 60
        {
            retryPendingHandOffs()
        }
        // Queued items with nobody transcribing them (a live session ended,
        // or a failed item has attempts left): give the inbox another pass.
        // `transcribing` with no live engine and no pass of ours running means
        // the transcriber died mid-item (watchdog, crash, reboot); a new pass
        // takes the inbox lock, which re-queues it.
        let waiting = recordings.contains { $0.state == .queued || $0.state == .transcribing }
        if waiting, processTask == nil, !liveEngineRunning(),
            Date().timeIntervalSince(lastProcessEnded ?? .distantPast) > 120
        {
            scheduleInboxProcess()
        }
        if tick % 4 == 0 { reloadDevices() }
    }

    private func apply(_ status: RemoteStatus, transcripts: [String], to id: String) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        var recording = recordings[index]
        let changed =
            recording.state != status.state || recording.progress != status.progress
            || recording.detail != status.detail || recording.transcripts != transcripts
        guard changed else { return }
        recording.state = status.state
        recording.progress = status.progress
        recording.detail = status.detail
        if !transcripts.isEmpty { recording.transcripts = transcripts }
        recording.updatedAt = status.updatedAt
        recordings[index] = recording
        saveIndex()
    }

    /// What the phone is told about `id`.
    fileprivate func status(for id: String) -> RemoteStatus {
        if pendingManifest(id) != nil {
            let detail = recordings.first { $0.id == id }?.detail ?? Self.noEngineDetail
            return RemoteStatus(recordingID: id, state: .received, detail: detail)
        }
        if let item = PhoneInbox.readStatus(root: inboxRoot, id: id) {
            return PhoneInbox.remoteStatus(for: item)
        }
        return .unknown(id)
    }

    fileprivate func transcript(for id: String) -> String? {
        guard let item = PhoneInbox.readStatus(root: inboxRoot, id: id) else { return nil }
        return PhoneInbox.transcript(for: item)
    }

    // MARK: pane actions

    func revealTranscript(_ recording: Recording) {
        let urls = recording.transcripts.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: persistence

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
            let decoded = try? JSONDecoder.wire.decode([Recording].self, from: data)
        else { return }
        recordings = decoded
    }

    private func saveIndex() {
        guard registry != nil, let data = try? JSONEncoder.wire.encode(recordings) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    // MARK: helpers

    private static func computerName() -> String {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty {
            return name
        }
        return Host.current().localizedName ?? "Mac"
    }

    /// Preview/render seam.
    func _previewInject(
        devices: [PairedDevice]? = nil, recordings: [Recording]? = nil, listening: Bool? = nil,
        invite: PairingInvite? = nil, paired: PairedDevice? = nil
    ) {
        if let devices { self.devices = devices }
        if let recordings { self.recordings = recordings }
        if let listening { isListening = listening }
        if let invite { activeInvite = invite }
        if let paired { pairedFromInvite = paired }
    }
}

// MARK: - SyncServerDelegate

extension PhoneSyncCoordinator: SyncServerDelegate {
    func syncServer(
        _ server: SyncServer, didReceive manifest: RecordingManifest, fileURL: URL,
        from device: PairedDevice
    ) async -> RemoteStatus {
        await receive(manifest: manifest, fileURL: fileURL)
    }

    func syncServer(_ server: SyncServer, statusFor recordingIDs: [String]) async -> [RemoteStatus] {
        recordingIDs.map { status(for: $0) }
    }

    func syncServer(_ server: SyncServer, transcriptFor recordingID: String) async -> String? {
        transcript(for: recordingID)
    }

    nonisolated func syncServerDevicesChanged(_ server: SyncServer) {
        Task { @MainActor in self.reloadDevices() }
    }

    nonisolated func syncServerEngineAvailable(_ server: SyncServer) -> Bool {
        engineAvailableFlag.withLock { $0 }
    }
}

extension JSONEncoder {
    /// Same date format as the sync wire (ISO 8601 with offset).
    static var wire: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(WireDate.format(date))
        }
        return encoder
    }
}

extension JSONDecoder {
    static var wire: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = WireDate.parse(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: text)
            }
            return date
        }
        return decoder
    }
}
