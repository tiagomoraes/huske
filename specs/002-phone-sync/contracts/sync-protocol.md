# Contract: Huske phone ↔ Mac sync protocol (v1)

**Status**: v1. Implemented in Swift by the shared `HuskeSync` library
(`macos/Sources/HuskeSync`), used by the iPhone app (client) and Huske.app on
the Mac (server). Both sides live in this repo and ship together; any wire change
bumps `protocolVersion`.

## Goals

- A recording made on the iPhone lands on the user's own Mac and is transcribed
  there, without a cloud service and without accounts.
- Pair once by pointing the iPhone camera at a QR code on the Mac.
- Transfers are authenticated and encrypted, resumable, and idempotent: the
  same recording is never transcribed twice, and an interrupted upload resumes.

## Discovery

- Bonjour service type **`_huske-sync._tcp`** in the `local.` domain.
- Service name: the Mac's computer name (informational only).
- TXT record keys:
  - `v` = `1` (protocol version)
  - `mac` = the Mac's stable **macID** (UUID string, generated once and stored
    by Huske.app)
- Both sides set `NWParameters.includePeerToPeer = true` so the iPhone can
  reach a nearby Mac over AWDL (peer-to-peer Wi-Fi, as AirDrop does) even when
  they are not on the same Wi-Fi network.
- The client looks for the service whose TXT `mac` equals its paired macID. It
  never connects to an unpaired Mac.

## Security

- TCP + **TLS 1.2 with a pre-shared key**, cipher suite
  `TLS_PSK_WITH_AES_128_GCM_SHA256`. This is the pattern Apple's
  Network.framework peer-to-peer sample uses for pairing.
- TLS session resumption and tickets are **disabled** on both sides, so every
  connection proves knowledge of the key.
- **PSK identity** = the phone's `deviceID` (UUID string, minted by the Mac at
  pairing time). **PSK** = 32 random bytes minted by the Mac at pairing time.
- The server registers every known device's PSK on its listener and uses the
  PSK selection block to pick the identity the client offered. Unknown identity
  → handshake fails (`unknown PSK identity`); wrong key → `bad MAC`.
- When a new pairing invite is created or a device is removed, the server
  restarts its listener with the updated key set. Clients always resolve via
  Bonjour, so a port change is harmless.

## Pairing

1. On the Mac, the user opens **iPhone → Pair iPhone**. Huske.app mints a
   pending slot `{deviceID, key, expiresAt = now + 10 min}` and shows a QR code
   encoding the **pairing URL**:

   ```text
   huske://pair?v=1&mac=<macID>&name=<macName, percent-encoded>&id=<deviceID>&exp=<Unix seconds>&key=<base64url key, no padding>
   ```

2. Scanning the QR with the iPhone Camera app opens the Huske iPhone app via
   the `huske` URL scheme (the app also has its own scanner, and accepts the URL
   pasted as text — the Mac shows a **Copy link** button for Universal
   Clipboard).
3. The iPhone stores `{macID, macName, deviceID, key}` in its Keychain and
   connects. The first successful `hello` with a pending slot's identity
   promotes it to **paired** and the Mac UI shows the device name.
4. A pending slot that was never used expires after 10 minutes. A paired device
   is valid until removed on the Mac (or "Forget this Mac" on the iPhone).

## Framing

After TLS, both directions carry **messages**:

```text
+----------------------+----------------------+---------------------------+
| UInt32 BE: headerLen | headerLen bytes JSON | header.bodyLength bytes   |
+----------------------+----------------------+---------------------------+
```

- `headerLen` ≤ 65 536. The header is a UTF-8 JSON object with a `type` string.
- `bodyLength` (integer, optional, default 0) ≤ 1 048 576 (1 MiB).
- Strict request → response, one outstanding request per connection, client
  speaks first. Dates are ISO 8601 with a UTC offset
  (`2026-11-19T14:03:00-03:00`).

## Messages

| Client request | Server response | Notes |
|---|---|---|
| `hello {protocolVersion, deviceID, deviceName, deviceModel, appVersion}` | `welcome {protocolVersion, macID, macName, serverVersion, engineAvailable}` | Must be first. Marks a pending slot as paired; updates name/lastSeen. `engineAvailable` = the Mac has a usable huske engine. |
| `offer {recording: RecordingManifest}` | `offerReply {recordingID, action, offset}` | `action` = `send` (stream from `offset`) or `skip` (Mac already has it verified). `offset` = bytes the Mac already holds for this ID (resume). |
| `chunk {recordingID, offset}` + body | `chunkAck {recordingID, received}` | `offset` must equal the server's current size, else `error offset_mismatch` carrying `received`. Recommended body size 256 KiB. |
| `commit {recordingID}` | `committed {status: RemoteStatus}` | Server verifies `byteCount` + `sha256`; on mismatch it discards the partial file and replies `error checksum_mismatch` (client restarts from 0). |
| `status {recordingIDs: [String]}` | `statusReply {items: [RemoteStatus]}` | Unknown IDs come back with state `unknown`. |
| `transcript {recordingID}` | `transcriptReply {recordingID, available}` + body | Body = UTF-8 Markdown (all transcript chunks of the recording, frontmatter stripped, joined in order). `available=false` → empty body. |
| `bye {}` | — | Server closes. |

Any request may be answered with `error {code, message, received?}`. Codes:
`version_mismatch`, `not_hello`, `bad_request`, `offset_mismatch`,
`checksum_mismatch`, `too_large`, `unknown_recording`, `internal`.

Client-side only: `wrong_mac` (the `welcome` came from a Mac other than the
paired one) is raised by the phone, never sent on the wire.

### RecordingManifest

```json
{
  "id": "4E1C0A5B-0F7E-4C67-9C0B-3C8F3A1B2D11",
  "title": "Reunião com a Ana",
  "startedAt": "2026-11-19T14:03:00-03:00",
  "durationSeconds": 1834.5,
  "byteCount": 14801234,
  "sha256": "<64 lowercase hex>",
  "fileExtension": "m4a",
  "contentType": "audio/mp4",
  "sampleRate": 48000,
  "channels": 1,
  "timeZone": "America/Sao_Paulo",
  "deviceName": "iPhone de Tiago"
}
```

`id` matches `^[A-Za-z0-9._-]{1,64}$` and does not start with `.` (same rule as the engine inbox). `byteCount` ≤ 4 GiB.

### RemoteStatus

```json
{
  "recordingID": "4E1C…",
  "state": "transcribed",
  "detail": "3 transcript chunks",
  "updatedAt": "2026-11-19T14:40:12-03:00",
  "progress": 1.0
}
```

`state` is one of:

| state | meaning |
|---|---|
| `unknown` | The Mac has never seen this ID. |
| `receiving` | Partial upload staged on the Mac. |
| `received` | Upload verified; not yet handed to the engine (e.g. engine missing). |
| `queued` | In the engine inbox, waiting for the transcriber. |
| `transcribing` | The engine is transcribing it (`progress` 0…1 when known). |
| `transcribed` | Transcript(s) written on the Mac. Terminal. |
| `failed` | The engine gave up (`detail` says why). Terminal until retried on the Mac. |

## Client behaviour (iPhone)

- Uploads start automatically when a recording stops and the paired Mac is
  reachable; queued recordings retry whenever the Mac reappears on Bonjour, when
  the app becomes active, and from background tasks.
- After `committed`, the client polls `status` while connected until the
  recording is terminal, then fetches the `transcript` once and stores it
  locally for reading on the phone.
- The phone keeps its own audio until the user deletes it.
