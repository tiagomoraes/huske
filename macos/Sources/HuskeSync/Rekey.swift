// Key rotation (sync-protocol.md § Key rotation): how the new key of a
// `rekey` travels.
//
// The connection is TLS with a pre-shared key and no key exchange of its own,
// so whoever holds that key and recorded the connection can read it later.
// The key being replaced is exactly the one that may have leaked (it was in a
// QR code and a copyable link), so the new one must not travel under it
// alone: the phone sends an ephemeral X25519 public key, the Mac answers
// with its own, and the new key is sealed under what only the two of them
// can derive.

import CryptoKit
import Foundation

enum RekeyExchange {
    /// The phone's half: keep `privateKey` until the answer arrives.
    struct Request {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()

        var message: RekeyMessage {
            RekeyMessage(publicKey: Base64URL.encode(privateKey.publicKey.rawRepresentation))
        }
    }

    /// Throws unless `request` carries a usable X25519 public key.
    static func check(_ request: RekeyMessage) throws {
        _ = try publicKey(request.publicKey)
    }

    /// Mac side: seals `credential` to the phone's ephemeral key.
    static func seal(
        _ credential: DeviceCredential, for request: RekeyMessage, oldDeviceID: String, oldKey: Data
    ) throws -> RekeyedMessage {
        let peer = try publicKey(request.publicKey)
        let own = Curve25519.KeyAgreement.PrivateKey()
        let context = Self.context(oldDeviceID: oldDeviceID, newDeviceID: credential.deviceID)
        let wrapping = try own.sharedSecretFromKeyAgreement(with: peer)
            .hkdfDerivedSymmetricKey(using: SHA256.self, salt: oldKey, sharedInfo: context, outputByteCount: 32)
        let sealed = try ChaChaPoly.seal(credential.key, using: wrapping, authenticating: context)
        return RekeyedMessage(
            deviceID: credential.deviceID,
            publicKey: Base64URL.encode(own.publicKey.rawRepresentation),
            sealedKey: Base64URL.encode(sealed.combined))
    }

    /// Phone side: the credential in `reply`. Throws when it was not sealed
    /// for this request, or is not a usable credential.
    static func open(
        _ reply: RekeyedMessage, for request: Request, oldDeviceID: String, oldKey: Data, now: Date = .now
    ) throws -> DeviceCredential {
        guard SyncConstants.isValidID(reply.deviceID), reply.deviceID != oldDeviceID,
            let sealedBytes = Base64URL.decode(reply.sealedKey)
        else { throw malformed("not a usable credential") }
        let peer = try publicKey(reply.publicKey)
        let context = Self.context(oldDeviceID: oldDeviceID, newDeviceID: reply.deviceID)
        let wrapping = try request.privateKey.sharedSecretFromKeyAgreement(with: peer)
            .hkdfDerivedSymmetricKey(using: SHA256.self, salt: oldKey, sharedInfo: context, outputByteCount: 32)
        let key: Data
        do {
            key = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: sealedBytes), using: wrapping, authenticating: context)
        } catch {
            throw malformed("the new key did not open")
        }
        guard key.count == 32 else { throw malformed("the new key is not 32 bytes") }
        return DeviceCredential(deviceID: reply.deviceID, key: key, issuedAt: now)
    }

    private static func publicKey(_ text: String) throws -> Curve25519.KeyAgreement.PublicKey {
        guard let raw = Base64URL.decode(text), raw.count == 32,
            let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
        else { throw malformed("publicKey is not an X25519 key") }
        return key
    }

    /// Binds the sealed key to this exchange: which credential it replaces
    /// and which it is.
    private static func context(oldDeviceID: String, newDeviceID: String) -> Data {
        Data("huske-sync/rekey/1\u{0}\(oldDeviceID)\u{0}\(newDeviceID)".utf8)
    }

    private static func malformed(_ why: String) -> SyncError {
        .protocolError(code: ErrorCode.badRequest.rawValue, message: "rekey: \(why)")
    }
}
