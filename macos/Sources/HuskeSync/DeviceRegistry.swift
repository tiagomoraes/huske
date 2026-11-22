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
    func markPaired(deviceID: String, name: String?, model: String?, now: Date = .now) -> Bool {
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
            stored.devices[index] = device
            persistLocked()
            return true
        }
    }

    /// Updates lastSeen (and name/model from hello). Returns true when
    /// something user-visible changed.
    @discardableResult
    func touch(deviceID: String, name: String?, model: String?, now: Date = .now) -> Bool {
        lock.withLock {
            guard let index = stored.devices.firstIndex(where: { $0.deviceID == deviceID })
            else { return false }
            var device = stored.devices[index]
            let visibleChange =
                (name.map { !$0.isEmpty && $0 != device.name } ?? false)
                || (model.map { !$0.isEmpty && $0 != device.model } ?? false)
            if let name, !name.isEmpty { device.name = name }
            if let model, !model.isEmpty { device.model = model }
            device.lastSeenAt = now
            stored.devices[index] = device
            persistLocked()
            return visibleChange
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
            }
            return keys
        }
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
