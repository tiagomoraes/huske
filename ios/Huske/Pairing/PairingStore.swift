// Where the iPhone keeps its pairing (the Mac's identity + this phone's PSK).
// The key never leaves the Keychain except to open a TLS-PSK connection.

import Foundation
import HuskeSync
import Security

protocol PairingStoring: AnyObject {
    func load() -> PairedMac?
    func save(_ mac: PairedMac) throws
    func clear()
}

final class KeychainPairingStore: PairingStoring {
    private let service: String
    private let account = "paired-mac"

    init(service: String = "cloud.tiagomoraes.huske.ios.pairing") {
        self.service = service
    }

    func load() -> PairedMac? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(PairedMac.self, from: data)
    }

    func save(_ mac: PairedMac) throws {
        let data = try JSONEncoder().encode(mac)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // Background sync runs while locked; never migrates to another device.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery()
            add.merge(attributes) { $1 }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "Couldn't save the pairing in the Keychain (\(text))."
        }
    }
}

/// For demo mode and tests.
final class InMemoryPairingStore: PairingStoring {
    private var mac: PairedMac?

    init(_ mac: PairedMac? = nil) {
        self.mac = mac
    }

    func load() -> PairedMac? { mac }
    func save(_ mac: PairedMac) throws { self.mac = mac }
    func clear() { mac = nil }
}
