# Contract: Huske phone ↔ Mac sync protocol (v1)

**Status**: v1. Implemented in Swift by the shared `HuskeSync` library
(`macos/Sources/HuskeSync`), used by the iPhone app (client) and Huske.app on
the Mac (server). Both sides live in this repo, but they reach users through
different channels and update at different times, so any pair may be a mixed
one: see [Versioning and capabilities](#versioning-and-capabilities) for how
the wire is allowed to change.

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
  - `v` = `1` (the highest protocol version the Mac speaks; informational —
    the phone does not filter on it, the version is settled in `hello`)
  - `mac` = the Mac's stable **macID** (UUID string, generated once and stored
    by Huske.app)
- Both sides set `NWParameters.includePeerToPeer = true` so the iPhone can
  reach a nearby Mac over AWDL (peer-to-peer Wi-Fi, as AirDrop does) even when
  they are not on the same Wi-Fi network.
- The client looks for the service whose TXT `mac` equals its paired macID. It
  never connects to an unpaired Mac.
- Not being able to browse is not "Mac not found": Local Network privacy
  denial (`kDNSServiceErr_PolicyDenied`) is reported as such at once, and a
  browser still waiting for the network when time runs out says why. A browser
  that fails (iOS resets a suspended app's mDNSResponder connection) is
  replaced with backoff (1, 2, 4 … 30 s).
- The Mac keeps its side of this up by itself. A listener that fails is
  rebuilt with the same backoff. It counts as reachable only once the system
  confirms the registration: an advert that never registers, or is withdrawn,
  is announced again by rebuilding the listener, and after a wake or a network
  change the Mac looks for its own advert the way a phone does. Rebuilding may
  change the port, which is why clients resolve through Bonjour every time.

## Security

- TCP + **TLS 1.2 with a pre-shared key**, cipher suite
  `TLS_PSK_WITH_AES_128_GCM_SHA256`. This is the pattern Apple's
  Network.framework peer-to-peer sample uses for pairing.
- TLS session resumption and tickets are **disabled** on both sides, so every
  connection proves knowledge of the key.
- **PSK identity** = the phone's `deviceID` (UUID string, minted by the Mac).
  **PSK** = 32 random bytes minted by the Mac (`SecRandomCopyBytes`). The
  pairing link carries the first identity and key; right after pairing they
  are replaced by a pair that never left the two devices
  ([Key rotation](#key-rotation)).
- The server registers every known device's PSK on its listener and uses the
  PSK selection block to pick the identity the client offered. Unknown identity
  → handshake fails (`unknown PSK identity`); wrong key → `bad MAC`.
- The selection block is the gate: it accepts an identity only while the
  device registry holds it as a pending slot that has not expired or as a
  paired device. A removed device and an expired invite are therefore refused
  at the handshake at once, even though the listener still carries their keys.
- A running listener cannot be given a new key, and replacing it takes the
  Bonjour advert down for about a second (every phone watching sees the Mac
  vanish). So each listener starts with 64 **spare slots** — random
  identities and keys nobody has been shown, unusable until the registry
  knows one — and a pairing takes two of them: one for the invite, one for
  the key that replaces the invite's. Creating an invite, an invite expiring,
  rotating a key and removing a device leave the listener alone. With fewer
  than 16 spares left the listener is replaced (it then carries every key in
  the registry plus a full set of spares) **at a quiet moment**: no
  connection open, nothing for 60 s, no pairing code waiting to be scanned.
  64 is 32 pairings without one such moment, so in practice the advert never
  goes away because of pairing; should the spares still run out, an invite
  replaces the listener at once and `rekey` answers `unavailable`. Clients
  always resolve via Bonjour, so a port change is harmless. A listener that
  fails at runtime is replaced the same way, with backoff (1, 2, 4 … 30 s).
- TCP keepalive is on at both ends: first probe after 30 s of silence, then
  every 5 s, 4 unanswered probes drop the connection. A peer that vanished
  without closing (out of Wi-Fi range, asleep) is noticed within 50 s.
- A TLS error **after** the handshake completed (a damaged record, a torn-down
  session) is a dropped connection, not a key problem: the client retries and
  resumes rather than asking the user to pair again.

## Pairing

1. On the Mac, the user opens **iPhone → Pair iPhone**. Huske.app mints a
   pending slot `{deviceID, key, expiresAt = now + 10 min}` and shows a QR code
   encoding the **pairing URL**:

   ```text
   huske://pair?v=1&mac=<macID>&name=<macName, percent-encoded>&id=<deviceID>&exp=<Unix seconds>&key=<base64url key, no padding>
   ```

   `v` is the version of the **link format**, not the protocol version: a
   link is read by whatever app is on the phone, so it must keep parsing
   across protocol bumps. Parsers ignore query items they do not know and
   refuse any `v` other than `1`; `v` changes only if the link itself changes
   incompatibly.

2. Scanning the QR with the iPhone Camera app opens the Huske iPhone app via
   the `huske` URL scheme (the app also has its own scanner, and accepts the URL
   pasted as text — the Mac shows a **Copy link** button for Universal
   Clipboard).
3. The iPhone stores `{macID, macName, deviceID, key}` in its Keychain and
   connects. The first successful `hello` with a pending slot's identity
   promotes it to **paired** and the Mac UI shows the device name.
4. A pending slot that was never used expires after 10 minutes. A paired device
   is valid until removed on the Mac, or on the iPhone with "Forget this Mac"
   ([Unpairing](#unpairing)).
5. With both sides announcing `pairing.rekey`, the key the link carried is
   replaced within the same pass ([Key rotation](#key-rotation)).

### Key rotation

**Threat model.** A pairing link is a QR code on a screen and a string on a
clipboard, so whoever keeps a copy (clipboard history, a forwarded
screenshot) would hold that iPhone's key for good — and, TLS-PSK having no
forward secrecy, could read a capture of its connections. Rotation makes the
copy worthless once the intended phone has paired: the key in use afterwards
was generated on the Mac, never shown, and delivered sealed to an ephemeral
key, so neither the link nor the link plus a capture of the whole exchange
yields it.

Not covered: someone who uses the link *before* the intended phone does (that
phone is then refused, and the Mac lists a device the user did not pair), and
an active attacker who holds the link and sits in the path of that first
connection.

Capability `pairing.rekey`; used only when both sides announce it.

| Client request | Server response |
|---|---|
| `rekey {publicKey}` | `rekeyed {deviceID, publicKey, sealedKey}` |

- `publicKey` (both ways): an ephemeral X25519 public key, base64url.
  `sealedKey`: the new 32-byte PSK, ChaCha20-Poly1305 (`nonce ‖ ciphertext ‖
  tag`, base64url) under `HKDF-SHA256(X25519 shared secret, salt = the key
  being replaced, info = "huske-sync/rekey/1" ‖ 0x00 ‖ old deviceID ‖ 0x00 ‖
  new deviceID)`, with the same `info` as associated data.
- **The new credential has a new identity.** A running listener cannot be
  given a key, and one PSK identity cannot have two keys, so the Mac hands
  out one of the listener's spare slots: `rekeyed.deviceID` is the phone's
  `deviceID` from then on. Nothing else about the device changes (name,
  pairing date, install ID); the listener and its advert are not touched.
- **Two keys, then one.** The Mac stores the new credential with the device
  *before* answering, and from then on accepts both. The first `hello` made
  with the new one is the proof: with that write it becomes the device's only
  credential, the old one is refused at the handshake, and connections still
  open under it are closed. Until then the old one keeps working, for as long
  as it takes.
- **The phone** stores the new credential next to the one in use (`pending`)
  before using it, then connects with it at once. The Mac's `welcome` on that
  connection promotes it; the pass carries on over that connection.
- **Idempotent.** Asking again while a credential is pending returns the same
  one (a lost answer costs no slot). With no spare slot left the answer is
  `error unavailable`; the phone asks again on a later connection.
- A pairing made before rotation existed is rotated the same way, the first
  time both sides announce the capability.

What each interruption leaves behind — the invariant being that the phone
always holds a key the Mac accepts:

| Interrupted at | Mac | Phone | Next |
|---|---|---|---|
| `rekeyed` lost, or the phone quits before storing it | old + new | old | Old key works. The phone asks again and gets the same credential. |
| The phone cannot store it (Keychain) | old + new | old | It is not used. Same as above. |
| The phone quits after storing, before using it | old + new | old + pending | Pending goes first at the next connection, and is promoted. |
| The Mac quits before the new key is used | old + new (on disk) | old + pending | The next listener carries both. As above. |
| `welcome` to the new key lost (the Mac already retired the old one) | new | old + pending | Pending goes first: accepted. |
| The Mac no longer knows the pending key (registry rewritten by an older Huske.app) | old | old + pending | Pending is refused, the old key works, and the next `rekeyed` replaces the pending one. |

The phone's rule with two keys stored: **the pending one first**. Only a
*refusal* of it (a failed handshake) lets the old key have a turn; a timeout
or a network error says nothing about keys. If the old key works, the pending
one is kept — a connection that drops before `welcome` reads exactly like a
refusal — until the Mac's next `rekeyed` confirms or replaces it. If the old
key is refused too, the pending one is tried once more (its first attempt may
have reached the Mac with only the answer lost) before the phone concludes it
was unpaired. A key is never dropped on the phone's own judgement.

Both sides keep the old layout readable: the phone's stored pairing and the
Mac's registry only gain optional fields, and after a rotation each holds an
ordinary `{deviceID, key}`, so an older build of either app installed over a
newer one keeps working.

### Unpairing

Capability `pairing.unpair`; used only when both sides announce it.

| Client request | Server response |
|---|---|
| `unpair {}` | `unpaired {}`, then the Mac closes the connection |

"Forget this Mac" on the iPhone forgets locally at once, whatever happens
next. If the Mac is visible right now and announced the capability at its
last `welcome`, the phone then connects (with whichever of its keys the Mac
takes) and sends `unpair`: the Mac removes the device this connection
authenticated as — never another — with any pending credential, and closes
its other connections. If the Mac is not reachable or predates the message,
it keeps listing the iPhone until it is removed there (**Remove** in the
iPhone pane); the key stays valid until then.

### Pairing again

`hello` may carry `installID`: a random ID (`^[A-Za-z0-9._-]{1,64}$`) that is
stable for one install of the iPhone app. The phone keeps it in its Keychain,
this device only: it survives pairing again, "Forget this Mac" and
reinstalling the app on the same iPhone, and is not carried to another iPhone
by a backup or a transfer. It needs no capability — an older Mac ignores the
key — and anything that is not a usable ID is treated as absent.

**A `hello` with an `installID` says "this is the pairing this install
keeps".** The Mac records it on the device and removes every *other* paired
device with the same `installID`, closing their connections: a phone holds
one pairing, so those are leftovers whose keys still worked. For that to be
safe the phone sends `installID` only with the pairing it has stored — never
while it tries a new code next to a pairing that still works (see
[Client behaviour](#client-behaviour-iphone)); it follows on the next
connection, normally the one that proves the rotated key a moment later.
Devices without an `installID` are never removed this way; for those the Mac
keeps its "looks like an earlier pairing" hint and the manual Remove.

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
| `hello {protocolVersion, deviceID, deviceName, deviceModel, appVersion, capabilities?, installID?}` | `welcome {protocolVersion, macID, macName, serverVersion, engineAvailable, capabilities?}` | Must be first, and only once (a second `hello` is `bad_request`). Settles the version and capabilities — see [Versioning and capabilities](#versioning-and-capabilities). Marks a pending slot as paired; updates name/lastSeen. `engineAvailable` = the Mac has a usable huske engine. |
| `offer {recording: RecordingManifest}` | `offerReply {recordingID, action, offset}` | `action` = `send` (stream from `offset`) or `skip` (the Mac needs no bytes; `offset` = `byteCount`). `skip` is decided by the recording ID alone, when the Mac holds a verified copy that is waiting for or being handed to the engine, or when the engine already knows the ID in any state other than `unknown` / `receiving`. For `send`, `offset` = bytes the Mac already holds for this ID (resume): the staged bytes are kept only if `sha256` and `byteCount` match the earlier offer, otherwise it is 0. |
| `chunk {recordingID, offset}` + body | `chunkAck {recordingID, received}` | `offset` must equal the server's current size, else `error offset_mismatch` carrying `received`. Any body up to the frame limit (1 MiB) is accepted; the phone starts at 256 KiB and follows the link ([Chunk size](#chunk-size)). |
| `commit {recordingID}` | `committed {status: RemoteStatus}` | Server verifies `byteCount` + `sha256`; on mismatch it discards the partial file and replies `error checksum_mismatch` (client restarts from 0). A recording is verified and handed to the engine once at a time: while that runs, an `offer` of the same ID answers `skip`, a `chunk` for it is `unknown_recording`, and a second `commit` is acknowledged with state `received` without a second hand-off. |
| `status {recordingIDs: [String]}` | `statusReply {items: [RemoteStatus]}` | Unknown IDs come back with state `unknown`. The Mac accepts ≤ 1000 IDs, but the reply must fit the header limit: clients ask ≤ 50 per request, the Mac cuts `detail` to 512 UTF-8 bytes, and a reply that still does not fit is answered `error too_large` (the connection stays up). |
| `transcript {recordingID}` | `transcriptReply {recordingID, available, partial?}` + body | Body = UTF-8 Markdown (all transcript chunks of the recording, frontmatter stripped, joined in order). `available=false` → empty body. The body is one frame, so a transcript over 1 MiB is cut at a character boundary and ends with the line `[… truncated on the Mac]`; the full text stays on the Mac. With `transcript.partial`, a recording the Mac gave up on is answered with the parts it did transcribe and `partial: true` ([Partial transcripts](#partial-transcripts)); `partial` is absent on every other reply. |
| `rekey {publicKey}` | `rekeyed {deviceID, publicKey, sealedKey}` | Only with `pairing.rekey` announced by both sides ([Key rotation](#key-rotation)); otherwise `bad_request`. `unavailable` when the Mac has no spare slot right now. |
| `unpair {}` | `unpaired {}` | Only with `pairing.unpair` announced by both sides ([Unpairing](#unpairing)); otherwise `bad_request`. The Mac removes this device, answers, and closes. |
| `bye {}` | — | Server closes. |

`hello.installID` is described under [Pairing again](#pairing-again).

A message type the receiver does not know is a malformed frame: the Mac
answers `bad_request` and **hangs up**. So a new message is never sent on the
strength of "it will be ignored": it is sent only to a peer that announced
the capability it belongs to.

Any request may be answered with `error {code, message, received?}`. Codes:
`version_mismatch`, `not_hello`, `bad_request`, `offset_mismatch`,
`checksum_mismatch`, `too_large`, `unknown_recording`, `unavailable` (fine,
but not right now: ask again on a later connection), `internal`.

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
| `failed` | The engine gave up (`detail` says why). Terminal until retried: from the Mac's iPhone pane, or by the phone offering the recording again ([Retrying](#after-the-upload-hand-off-and-retrying)). |

A status may carry optional extras. Each belongs to a capability and is sent
only on a connection where **both** sides announced it; the Mac strips the
others, so a phone that did not announce a capability receives exactly the
five fields above, with the same values. A phone ignores extras of a
capability the Mac did not announce.

| field | capability | meaning |
|---|---|---|
| `partial` (bool) | `transcript.partial` | `true` on a `failed` recording of which some parts were transcribed: `transcript` serves them. Absent otherwise. |
| `partsDone`, `partsTotal` (int) | `transcript.partial` | With `partial`: how many of the recording's parts were transcribed, and how many it was split into. |
| `retrying` (bool) | `status.retry` | `true` while the Mac will try again by itself after an error: `state` is `queued` (the engine failed with attempts left) or `received` (the hand-off to the engine failed). Absent otherwise. |
| `attempt`, `maxAttempts` (int) | `status.retry` | With `retrying`, when the tries are counted (the engine's): the try that comes next (2 after the first failure) and how many are made before `failed`. Absent for the hand-off, which is retried without a limit. |

```json
{
  "recordingID": "4E1C…",
  "state": "failed",
  "detail": "chunk 2/3 failed: …",
  "updatedAt": "2026-11-19T14:52:40-03:00",
  "partial": true,
  "partsDone": 2,
  "partsTotal": 3
}
```

`detail` is unchanged by the extras. A Mac that retries says so there too
(`Will retry after an error: …`, `Will retry: …`): that text is how phones
without `status.retry` recognise the state, so it is not reworded. A phone
with `status.retry` goes by `retrying` and reads `detail` only for the reason.

### Partial transcripts

Capability `transcript.partial`. A long recording is transcribed in parts
(inbox.md § Partial results). When the engine gives up with some parts
finished, the Mac reports `failed` with `partial: true` and answers
`transcript` with those parts, in order, and `transcriptReply.partial: true`.
The phone fetches them once (again if a later failure reports different
`partsDone` / `partsTotal`), shows them as partial, and keeps Retry: the
recording is still `failed`. A retry transcribes only the missing parts; when
it completes, `status` reads `transcribed` and `transcript` returns the whole
text, which replaces the partial one on the phone.

`transcriptReply.partial` is what makes the answer safe to act on: between
the `status` that said `partial` and the `transcript` request the recording may
have been retried on the Mac, and the reply is then the whole transcript
(no `partial`) or `available: false`.

Without the capability on both sides nothing changes: the status is a plain
`failed`, and `transcript` for it answers `available: false`.

## After the upload: hand-off and retrying

- **`committed` does not wait for the engine.** Once the checksum is verified
  the Mac moves the audio to a durable pending folder and answers
  `committed {status: {state: "received", …}}` at once; `huske inbox add` runs
  after the answer (one at a time), and is taken up again at the next launch
  and every minute if it did not finish. The phone keeps polling `status`
  (`received` is not terminal) and sees `queued` a moment later. Before, the
  answer waited for the engine, and a cold engine could outlast the phone's
  30 s reply timeout.
- **Retrying.** A recording the Mac holds as `failed` stays on the Mac with
  its audio, so there is nothing to send again. An `offer` of such a recording
  is the phone's Retry: the Mac re-queues it (the same `huske inbox retry` its
  own "Try again" runs, with a fresh attempt budget), **then** answers
  `offerReply {action: "skip"}`, so the `status` the phone asks for next reads
  `queued` and polling resumes. If the Mac cannot retry (no engine, the audio
  is gone, a retry is already running) the answer is still `skip` and `status`
  still says `failed`. The Mac acts on at most one such request per recording
  every 30 s. There is no retry message and no version bump: a phone that
  never re-offers behaves exactly as before, and an older Mac simply answers
  `skip` without retrying.

## Versioning and capabilities

The iPhone app and Huske.app update separately, so the protocol has to keep
working between any two versions of them. Three rules do that.

1. **Unknown JSON keys are ignored**, at every level of every message. Adding
   a field is never a breaking change; removing or re-typing one is.
2. **Additive features are announced as capabilities.** `hello` and `welcome`
   may carry `capabilities`: a list of short feature names (`"area.feature"`).
   A missing key means none, and names the receiver does not know are ignored.
   A peer uses a feature only if the other side announced it; otherwise it
   behaves exactly as v1 without that feature. The names in use are listed
   under [Capabilities](#capabilities).
3. **`protocolVersion` is negotiated, and bumped only for a breaking change.**
   `hello.protocolVersion` is the *highest* version the phone speaks. The Mac
   accepts any version from the oldest it still speaks upward and answers with
   `welcome.protocolVersion = min(phone's, Mac's)`: the version this
   connection speaks. The phone accepts a `welcome` whose version is at most
   its own (and at least the oldest it still speaks); anything else is a
   `version_mismatch` raised on the phone. The Mac replies
   `error version_mismatch` and closes only when the phone's highest version
   is older than the oldest the Mac still speaks.

So a newer iPhone app talks to an older Huske.app (and the reverse) in the
older of the two versions, and a feature both sides have is used whichever
side updated first. Today both the highest and the oldest version are `1`.
The pairing link's `v` and the Bonjour TXT `v` do not take part in this.

### Capabilities

| name | what both sides may then do |
|---|---|
| `transcript.partial` | `RemoteStatus.partial` / `partsDone` / `partsTotal`, and `transcript` serving the transcribed parts of a `failed` recording ([Partial transcripts](#partial-transcripts)). |
| `status.retry` | `RemoteStatus.retrying` / `attempt` / `maxAttempts` ([RemoteStatus](#remotestatus)). |
| `pairing.rekey` | `rekey` / `rekeyed`: the key the pairing link carried is replaced by one that never left the two devices ([Key rotation](#key-rotation)). |
| `pairing.unpair` | `unpair` / `unpaired`: "Forget this Mac" also removes the iPhone on the Mac ([Unpairing](#unpairing)). |

Additive, and deliberately **not** capabilities:

| what | why it needs none |
|---|---|
| `hello.installID` ([Pairing again](#pairing-again)) | A field of the first message: it is sent before the phone knows what the Mac announces, and a Mac that predates it ignores the key (rule 1). Its presence is the announcement. |
| Chunks larger than 256 KiB ([Chunk size](#chunk-size)) | Every version of the Mac accepts a chunk up to the frame limit; only the size the phone *chooses* changed. |

## Limits and timeouts

| What | Value | What happens |
|---|---|---|
| Header / body size | 64 KiB / 1 MiB | A frame over either limit is `too_large`, then the Mac hangs up (the stream position is lost). |
| Recording size | `byteCount` ≤ 4 GiB | `offer` → `bad_request`. |
| Chunk body | ≤ 1 MiB; the phone uses 64 KiB … 1 MiB ([Chunk size](#chunk-size)) | A chunk past `byteCount` is `too_large`. |
| Spare slots (Mac) | 64 per listener; replenished below 16, at a quiet moment | See [Security](#security). `rekey` with none left is `unavailable`. |
| `status` | ≤ 1000 IDs accepted; clients send ≤ 50; `detail` ≤ 512 UTF-8 bytes | See the `status` row above. |
| `transcript` body | ≤ 1 MiB | Cut at a character boundary with a truncation line. |
| Connect (phone) | 8 s by default for browse + TLS + `hello` | `macNotFound`, `timeout` or the transport's error. |
| Request (phone) | 30 s to send a request, 30 s more for its reply | The phone closes the connection and reports `timeout`; a later connection resumes from the Mac's `offset`. |
| TLS handshake (Mac) | 20 s from accept | The Mac drops the connection. |
| Idle (Mac) | 120 s without a complete request | The Mac closes the connection. The clock restarts with every request. The phone's next request then fails as a closed connection and it reconnects; nothing staged is lost. |
| Keepalive (both) | 30 s idle, then 4 probes 5 s apart | A peer that vanished without closing is dropped within 50 s. |
| Partial upload (Mac) | 7 days since its last byte | Dropped; the next `offer` answers `send` from 0. |
| Pairing invite | 10 minutes | Refused at the handshake once expired. |

### Chunk size

Uploads are stop-and-wait — one `chunk`, one `chunkAck` — so every chunk costs
a round trip on top of its bytes. At a fixed 256 KiB a two-hour recording
(58 MB) is 222 round trips: about 14 s through a link with 25 ms of latency
each way, most of it waiting. The phone therefore sizes each chunk from the last
one: it starts at 256 KiB, doubles after a chunk acknowledged in under 1 s
(up to 1 MiB, the frame limit), and halves after one that took over 5 s (down
to 64 KiB), so a slow link keeps its progress and its resume point
fine-grained and stays far from the 30 s request timeout. The same recording
over the same link: 57 chunks, about 4 s (measured with the `FaultProxy`
latency mode: `HUSKE_SYNC_MEASURE=1 swift test --filter ThroughputTests`).
Nothing changes on the wire, and the
Mac needs to know nothing: it has always accepted any chunk up to 1 MiB.

A request that fails in transit — it timed out, the connection dropped, the
reply could not be read — ends that connection on the phone: the stream is no
longer at a known position, so the phone closes it and connects again. So does
a request cancelled while in flight (its task was cancelled), because the
reply could no longer be told apart from the next request's. An `error` reply
from the Mac, and cancellation between requests, leave the connection usable.

## Client behaviour (iPhone)

- **One browse.** The phone keeps a single Bonjour browse for its paired Mac
  and connects to the endpoint that browse reports; it does not browse per
  attempt. The browse (and the network path monitor) run only while the app is
  on screen or a sync pass is running: in the background a pass starts the
  browse, waits up to 8 s for the Mac and stops it when it ends.
- **No connect without a Mac.** While the Mac is not visible nothing is
  attempted. A pass starts when a recording stops, the Mac appears on the
  browse or is seen another way (Wi-Fi ↔ peer-to-peer), the network path
  changes, the app becomes active, the user asks ("Sync now", pairing), or a
  background task runs.
- **Reconnecting.** A pass that fails while the Mac is still visible is retried
  after 2 s, doubling to 60 s, each ±20 %. Any of the events above resets the
  count and tries at once. A handshake the Mac refuses, `wrong_mac` and
  `version_mismatch` are not retried on a clock: they need the user.
- **Connecting.** The client resolves the Bonjour service to an address and
  connects to that, so a refused key is reported at once as a handshake
  failure. If that address gives no answer within 3 s it connects to the
  service itself. A path that is still coming up gets about 3 s before an
  attempt fails.
- **Pairing.** With a Mac already paired, the key from a new pairing link is
  tried first and replaces the stored pairing only after that Mac's `welcome`.
  A rejected or unreachable code leaves the existing pairing untouched. A first
  pairing is stored at once and confirmed by the first `welcome`; a first code
  the Mac refuses is discarded. While a new code is only being tried the
  `hello` carries no `installID` ([Pairing again](#pairing-again)): the Mac
  must not drop the entry of the pairing that still works.
- **Key rotation.** Right after `welcome`, when both sides announce
  `pairing.rekey` and the stored key is still the link's, the phone asks for
  a new one, stores it, proves it on a second connection and carries on over
  that one ([Key rotation](#key-rotation)). Nothing of it reaches the user:
  a rotation that cannot finish now finishes on a later pass, and the pass
  goes on with the key it has. A rotation still owed is itself a reason to
  connect, like a recording to send: the stored key is still the link's and
  the Mac's last `welcome` announced `pairing.rekey` (or no `welcome` from
  this build has been seen yet), or a `pending` key waits to be proven. So
  a rotation cut short — the Mac quit between `rekeyed` and the proof, a
  pairing an older build made — finishes the next time the Mac is seen, not
  at the next recording. A Mac known not to rotate, and a pairing the Mac
  refused, are not contacted for it.
- **Forgetting the Mac** forgets locally first, then tells the Mac if it can
  ([Unpairing](#unpairing)).
- **Network or file.** A failure of the way to the Mac (`SyncError.network`:
  refused, no route, name not resolved) ends the pass and is retried; a
  refused connection reads "… isn't accepting connections — open Huske on
  your Mac". A recording whose file cannot be read (`SyncError.io`) fails
  alone, and the pass goes on with the next one.
- After `committed`, the client polls `status` while connected until the
  recording is terminal, then fetches the `transcript` once and stores it
  locally for reading on the phone (for a `failed` recording only when the
  status says `partial`; those parts are stored apart from a transcript, so
  the recording still counts as not transcribed). It asks every 2 s while the Mac is
  transcribing and the app is on screen, easing off to every 10 s while
  recordings only wait; in the background it polls for 20 s. A pass with
  nothing to send, fetch, poll or rotate does not connect.
- **Retry** on a recording the Mac reports as `failed` offers it again
  ([Retrying](#after-the-upload-hand-off-and-retrying)) and resumes polling.
  Retry on a recording that could not be sent sends it again.
- **A failure is asked about again once per visit.** `failed` ends polling, so
  a recording tried again from the Mac's iPhone pane would stay "Couldn't
  transcribe" on the phone. Each time the app comes to the front, the next
  pass sends one `status` for the recordings it holds as `failed` and follows
  whatever is no longer failed (or fetches parts the Mac now offers). An
  `unknown` answer changes nothing: the recording is not sent again unasked.
  Failed recordings never start a pass at any other time.
- Deleting a recording on the phone stops its upload if one is running; the
  Mac discards the partial file in its own time.
- A cancelled upload (the user forgot the Mac, background time ran out) stops
  between chunks; the Mac keeps the bytes it has and a later `offer` resumes.
- The phone keeps its own audio until the user deletes it.
