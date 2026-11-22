// Which install of the app this is: a random ID the Mac uses to recognise an
// iPhone that pairs again, so the earlier entry is replaced instead of left
// behind with a key that still works (sync-protocol.md § Pairing again).
//
// It lives in the Keychain, this device only — the same place and lifetime as
// the pairing itself:
// - it survives pairing again, "Forget this Mac", and deleting and
//   reinstalling the app on the same iPhone (so does the Keychain), which are
//   exactly the cases that leave a stale entry on the Mac;
// - it does not travel to another iPhone with a backup or a transfer, so a
//   new phone is a new install and never displaces the old one's pairing.
// It names an install, not a person: it is sent only to a Mac the user
// paired, inside the encrypted connection.

import Foundation
import HuskeSync
import Security

enum InstallIdentity {
    static let service = "cloud.tiagomoraes.huske.ios.install"
    private static let account = "install-id"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: String?

    /// This install's ID, minted on first use. nil when the Keychain can't
    /// keep one (the Mac then falls back to its "looks like an earlier
    /// pairing" hint) — and in DEBUG builds standing in for an older app.
    static var current: String? {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "HuskeLegacyPeer") { return nil }
        #endif
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        cached = load(service: service)
        return cached
    }

    /// Reads the ID stored under `service`, minting and storing one first if
    /// there is none. nil when it can be neither read nor stored.
    static func load(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, let id = String(data: data, encoding: .utf8),
           SyncConstants.isValidID(id) {
            return id
        }
        // Mint only when there is none (or what is there is unusable). Any
        // other failure — the Keychain is locked until first unlock — must
        // not replace an ID that exists: no ID this time, the same one later.
        guard status == errSecItemNotFound || status == errSecSuccess else { return nil }
        let minted = UUID().uuidString
        var add = query
        add[kSecValueData as String] = Data(minted.utf8)
        // Sync runs in the background while locked; never leaves this device.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if status == errSecSuccess { SecItemDelete(query as CFDictionary) }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? minted : nil
    }

    static func remove(service: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}
