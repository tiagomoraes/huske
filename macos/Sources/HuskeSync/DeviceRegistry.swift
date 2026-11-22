// The Mac's sync identity (macID) and every phone it knows, pending or paired.
// One small JSON file; it holds the pre-shared keys, so it is written 0600 in
// a 0700 directory, atomically (temp file + rename).

import Foundation

public final class DeviceRegistry: @unchecked Sendable {
    private struct Stored: Codable {
        var macID: String
        var devices: [PairedDevice]
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var stored: Stored
    /// `noteContact` bookkeeping: contact times newer than the file.
    private var unsavedContact = false
    private var lastContactSave = Date.distantPast

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
            let decoded = try? WireJSON.decoder().decode(Stored.self, from: data)
        {
            stored = decoded
        } else {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                // Unreadable registry: keep it for forensics rather than
                // silently overwriting the keys it held.
                let aside = fileURL.appendingPathExtension("corrupt")
                try? FileManager.default.removeItem(at: aside)
                try? FileManager.default.moveItem(at: fileURL, to: aside)
            }
            stored = Stored(macID: UUID().uuidString, devices: [])
            persistLocked()
        }
    }

    /// Minted on first use, persisted.
    public var macID: String {
        lock.withLock { stored.macID }
    }

    public func devices() -> [PairedDevice] {
        lock.withLock { stored.devices }
    }

    public func device(id deviceID: String) -> PairedDevice? {
        lock.withLock { stored.devices.first { $0.deviceID == deviceID } }
    }

    /// The device a PSK identity belongs to: its own `deviceID`, or the
    /// `successor` a `rekey` issued and it has not used yet.
    func device(forIdentity identity: String) -> PairedDevice? {
        lock.withLock {
            stored.devices.first { $0.deviceID == identity || $0.successor?.deviceID == identity }
        }
    }

    public func addPending(_ invite: PairingInvite) {
        lock.withLock {
            stored.devices.removeAll { $0.deviceID == invite.deviceID }
            stored.devices.append(
                PairedDevice(
                    deviceID: invite.deviceID, key: invite.key, createdAt: Date(),
                    expiresAt: invite.expiresAt))
            persistLocked()
        }
    }

    public func remove(deviceID: String) {
        lock.withLock {
            let before = stored.devices.count
            stored.devices.removeAll { $0.deviceID == deviceID }
            if stored.devices.count != before { persistLocked() }
        }
    }

    // MARK: server-side mutators

    /// First successful hello for a pending slot. Returns false when the slot
    /// is unknown or expired.
    @discardableResult
    func markPaired(
        deviceID: String, name: String?, model: String?, installID: String? = nil, now: Date = .now
    ) -> Bool {
        lock.withLock {
            guard let index = stored.devices.firstIndex(where: { $0.deviceID == deviceID }),
                !stored.devices[index].isExpired(now: now)
            else { return false }
            var device = stored.devices[index]
            if device.pairedAt == nil { device.pairedAt = now }
            device.expiresAt = nil
            device.lastSeenAt = now
            if let name, !name.isEmpty { device.name = name }
            if let model, !model.isEmpty { device.model = model }
            if let installID { device.installID = installID }
            stored.devices[index] = device
            persistLocked()
            return true
        }
    }

    /// Updates lastSeen (and name/model from hello). Returns true when
    /// something user-visible changed.
    @discardableResult
    func touch(
        deviceID: String, name: String?, model: String?, installID: String? = nil, now: Date = .now
    ) -> Bool {
        lock.withLock {
            guard let index = stored.devices.firstIndex(where: { $0.deviceID == deviceID })
            else { return false }
            var device = stored.devices[index]
            let visibleChange =
                (name.map { !$0.isEmpty && $0 != device.name } ?? false)
                || (model.map { !$0.isEmpty && $0 != device.model } ?? false)
            if let name, !name.isEmpty { device.name = name }
            if let model, !model.isEmpty { device.model = model }
            if let installID { device.installID = installID }
            device.lastSeenAt = now
            stored.devices[index] = device
            persistLocked()
            return visibleChange
        }
    }

    // MARK: key rotation + re-pairing

    /// Records the credential a `rekey` issued for a paired device. The old
    /// one stays valid next to it until `promoteSuccessor`. False when the
    /// device is unknown or not paired.
    @discardableResult
    func setSuccessor(_ credential: DeviceCredential?, forDevice deviceID: String) -> Bool {
        lock.withLock {
            guard let index = stored.devices.firstIndex(where: { $0.deviceID == deviceID }),
                stored.devices[index].isPaired
            else { return false }
            stored.devices[index].successor = credential
            persistLocked()
            return true
        }
    }

    /// The phone used the credential `rekey` gave it: that credential becomes
    /// the device's only one, and the one it replaces stops working with this
    /// write. Returns the retired identity and the device as it is now, or
    /// nil when `identity` is no device's successor.
    func promoteSuccessor(identity: String, now: Date = .now) -> (retired: String, device: PairedDevice)? {
        lock.withLock {
            guard let index = stored.devices.firstIndex(where: { $0.successor?.deviceID == identity }),
                let successor = stored.devices[index].successor
            else { return nil }
            let old = stored.devices[index]
            let device = PairedDevice(
                deviceID: successor.deviceID, key: successor.key, name: old.name, model: old.model,
                createdAt: old.createdAt, pairedAt: old.pairedAt, lastSeenAt: now, expiresAt: nil,
                installID: old.installID, successor: nil, rotatedAt: now)
            stored.devices[index] = device
            persistLocked()
            return (old.deviceID, device)
        }
    }

    /// Drops every other paired entry of the install `installID`: a phone
    /// holds one pairing, and it just said which (`hello.installID`). Returns
    /// the removed device IDs.
    @discardableResult
    func removeOtherPairings(ofInstall installID: String, keeping deviceID: String) -> [String] {
        lock.withLock {
            let doomed = stored.devices
                .filter { $0.isPaired && $0.installID == installID && $0.deviceID != deviceID }
                .map(\.deviceID)
            guard !doomed.isEmpty else { return [] }
            stored.devices.removeAll { doomed.contains($0.deviceID) }
            persistLocked()
            return doomed
        }
    }

    /// Proof of life from a paired device: any request, not just `hello`, so
    /// a phone that stays connected to poll is not "last seen an hour ago".
    /// `devices()` sees it at once; the file is rewritten at most every
    /// `persistEvery` seconds, so an upload's chunks do not rewrite the
    /// registry hundreds of times.
    func noteContact(deviceID: String, now: Date = .now, persistEvery: TimeInterval = 30) {
        lock.withLock {
            guard let index = stored.devices.firstIndex(where: { $0.deviceID == deviceID })
            else { return }
            stored.devices[index].lastSeenAt = now
            unsavedContact = true
            guard now.timeIntervalSince(lastContactSave) >= persistEvery else { return }
            persistLocked()
            lastContactSave = now
            unsavedContact = false
        }
    }

    /// Writes the contact times `noteContact` kept in memory (a connection
    /// closed, the server is stopping).
    func flushContacts(now: Date = .now) {
        lock.withLock {
            guard unsavedContact else { return }
            persistLocked()
            lastContactSave = now
            unsavedContact = false
        }
    }

    /// Drops pending slots past their expiry. Returns the removed IDs.
    @discardableResult
    public func pruneExpired(now: Date = .now) -> [String] {
        lock.withLock {
            let expired = stored.devices.filter { $0.isExpired(now: now) }.map(\.deviceID)
            guard !expired.isEmpty else { return [] }
            stored.devices.removeAll { expired.contains($0.deviceID) }
            persistLocked()
            return expired
        }
    }

    /// Identity → key for every device whose slot is usable right now.
    func activeKeys(now: Date = .now) -> [String: Data] {
        lock.withLock {
            var keys: [String: Data] = [:]
            for device in stored.devices where !device.isExpired(now: now) {
                keys[device.deviceID] = device.key
                // A credential issued by `rekey` and not used yet: the next
                // listener must accept it too, or the phone holding it would
                // be turned away.
                if let successor = device.successor { keys[successor.deviceID] = successor.key }
            }
            return keys
        }
    }

    /// A pairing code is out and still valid: someone may be about to use it.
    func hasLiveInvite(now: Date = .now) -> Bool {
        lock.withLock { stored.devices.contains { !$0.isPaired && !$0.isExpired(now: now) } }
    }

    /// Earliest pending expiry, for scheduling a prune.
    func nextExpiry() -> Date? {
        lock.withLock {
            stored.devices.filter { !$0.isPaired }.compactMap(\.expiresAt).min()
        }
    }

    // MARK: persistence

    private func persistLocked() {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        try? fm.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard let data = try? Self.encoder.encode(stored) else { return }
        let temp = dir.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600])
        else { return }
        if rename(temp.path, fileURL.path) != 0 {
            try? fm.removeItem(at: temp)
            return
        }
        // rename keeps the temp file's mode; enforce it anyway in case an
        // older file with looser permissions was replaced by something else.
        _ = chmod(fileURL.path, 0o600)
    }

    private static var encoder: JSONEncoder {
        let encoder = WireJSON.encoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }
}
