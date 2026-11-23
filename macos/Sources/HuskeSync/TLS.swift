// TLS 1.2 with a pre-shared key, TLS_PSK_WITH_AES_128_GCM_SHA256 — the
// pattern Apple's Network.framework peer-to-peer sample uses for pairing.
//
// Things that are load-bearing and were learned the hard way:
// - Session resumption and tickets are OFF on both sides. With resumption on,
//   a reconnect with a *wrong* key succeeded through the cached session.
// - The server registers every known device's PSK on the listener and picks
//   one in the selection block. The block's "hint" is the identity the client
//   offered, and its completion takes the IDENTITY to use — not the key.

import Foundation
import Network
import Security

enum TLSPSK {
    /// TCP keepalive: first probe after `keepaliveIdle` seconds of silence,
    /// then every `keepaliveInterval`; `keepaliveCount` unanswered probes
    /// drop the connection — 30 + 4 × 5 = 50 s for a half-open one.
    static let keepaliveIdle = 30
    static let keepaliveInterval = 5
    static let keepaliveCount = 4

    static func clientParameters(identity: String, key: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        configureCommon(sec)
        sec_protocol_options_add_pre_shared_key(
            sec, dispatchData(key) as __DispatchData,
            dispatchData(Data(identity.utf8)) as __DispatchData)
        return parameters(tls: tls)
    }

    /// `keys` maps identity → key. `select` decides, per handshake, whether
    /// the identity the client offered is acceptable right now (a pending slot
    /// can expire while the listener runs) and records it for the connection.
    static func serverParameters(
        keys: [String: Data],
        queue: DispatchQueue,
        select: @escaping @Sendable (sec_protocol_metadata_t, String) -> Bool
    ) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        configureCommon(sec)
        for (identity, key) in keys {
            sec_protocol_options_add_pre_shared_key(
                sec, dispatchData(key) as __DispatchData,
                dispatchData(Data(identity.utf8)) as __DispatchData)
        }
        sec_protocol_options_set_pre_shared_key_selection_block(
            sec,
            { metadata, hint, complete in
                guard let hint else {
                    complete(nil)
                    return
                }
                let identity = String(decoding: Data(hint as DispatchData), as: UTF8.self)
                if keys[identity] != nil, select(metadata, identity) {
                    complete(dispatchData(Data(identity.utf8)) as __DispatchData)
                } else {
                    complete(nil)
                }
            }, queue)
        return parameters(tls: tls)
    }

    private static func configureCommon(_ sec: sec_protocol_options_t) {
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_tls_resumption_enabled(sec, false)
        sec_protocol_options_set_tls_tickets_enabled(sec, false)
        sec_protocol_options_append_tls_ciphersuite(
            sec, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
    }

    private static func parameters(tls: NWProtocolTLS.Options) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        // Idle alone leaves the probe interval and count at the system
        // defaults (75 s × 8): a peer that vanished without a FIN — Wi-Fi
        // dropped, the Mac slept — would hold the connection for ten minutes.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = keepaliveIdle
        tcp.keepaliveInterval = keepaliveInterval
        tcp.keepaliveCount = keepaliveCount
        let params = NWParameters(tls: tls, tcp: tcp)
        // AWDL (peer-to-peer Wi-Fi), as AirDrop does: works when the phone
        // and the Mac are not on the same network.
        params.includePeerToPeer = true
        return params
    }

    static func dispatchData(_ data: Data) -> DispatchData {
        data.withUnsafeBytes { DispatchData(bytes: $0) }
    }

    /// The TLS metadata of an established connection, if any.
    static func securityMetadata(of connection: NWConnection) -> sec_protocol_metadata_t? {
        (connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata)?
            .securityProtocolMetadata
    }
}
