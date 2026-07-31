---
status: superseded-by-0009
---

# Optional off-device huske server (push-replicated transcripts)

## Context

huske is local-first. ADR 0001 made `huske mcp` an always-on HTTP daemon but
bound it to `127.0.0.1`, explicitly rejected "HTTP-only with a tunnel for *all*
clients," and noted ChatGPT would reach it via a "user-provided tunnel
(documented, not built-in)." A future reader therefore knows the read endpoint
was *deliberately* never exposed to the network.

A new need pushes past that scope: the author runs an always-on agent
("hermes") that must query their huske context 24/7, but the recording Mac is
frequently asleep. A tunnel back to the Mac (ADR 0001's anticipated remote
path) cannot answer a query when the Mac is offline. A reader who saw
"loopback-only" will reasonably ask why a publicly reachable VPS now holds
transcripts.

This stays a **1% power feature**: 99% of users run the MCP locally over
loopback exactly as before, and pay nothing for any of it.

## Decision

An optional `huske serve` mode runs a single-tenant **huske server** on a VPS
holding a **Replica** of one user's transcripts.

- **Push the finalized `.md` Transcript.** The recording Mac pushes each
  finalized transcript to the server's authenticated **Ingest** endpoint,
  out-of-band from the recording loop. The send-path ships in *base* huske, is
  dependency-free (stdlib HTTP + a durable outbox), and is **inert until an
  endpoint + token are configured.**
- **The server re-derives everything from the `.md`.** It runs the same
  `parse → window → embed → store → MCP` pipeline as the local install, with a
  **non-Metal (CPU) embedder** — the `fastembed`/onnxruntime e5 fallback named
  in ADR 0002 — and owns its own vector space. The heavy deps live only behind
  `huske serve` (the `[mcp]` extra), on the VPS.
- **hermes is co-located on the VPS.** The MCP/read endpoint stays
  **loopback-bound on the server** — never network-exposed — exactly like the
  Mac's local daemon. The **only network-exposed endpoint is write-only
  Ingest**, behind a TLS-terminating reverse proxy; the app binds to loopback
  behind it.
- **Split credentials** fall out of the topology: a public **write token**
  (Ingest) distinct from the loopback **read token** (MCP).
- **Single-tenant.** One server holds exactly one user's Replica. Multi-tenant
  is out of scope.

## Why (the trade-off)

- **The Mac is ephemeral; hermes is not.** 24/7 access requires the queryable
  data to live where hermes always reaches it. Once a tunnel-to-Mac is ruled
  out by the Mac being offline, an off-device Replica is the only option.
- **Push `.md`, not vectors.** The server must embed *queries* itself, and the
  Mac — the only Metal machine — is offline at query time, so the server needs a
  full embedder regardless. Shipping pre-computed vectors then buys nothing and
  adds a cross-runtime vector-space hazard (MLX vs CPU e5). The `.md` is already
  the published contract (ADR 0003), so the server is just another consumer of
  it and live-ingest is the same code path as backfill.
- **Co-location collapses the public surface to one write-only door.** A stolen
  write token lets an attacker attempt to push junk (bounded by immutable,
  idempotent Ingest) but **never to read transcript history over the network.**
  Reading requires VPS shell access. Exposing the read MCP would put the whole
  history one token away from the internet; co-locating hermes avoids that.
- **Leanness preserved.** Server-side heavy deps plus a dependency-free,
  inert-by-default send-path mean the 99% local users carry no new weight.

## Consequences

- Project identity moves from "local-only" to **local-first**: capture and
  transcription stay on-device, but an opt-in off-device Replica now exists.
  `CONTEXT.md` is updated; `README.md` and `CLAUDE.md` "local-only" wording must
  follow.
- The VPS holds the **full plaintext transcript history**. Mandatory posture:
  TLS at the proxy; app bound to loopback behind it; DNS-rebinding allowlist
  seeded with the public host (`build_server(extra_allowed_hosts=...)`, since
  `_allowed_hosts` only seeds loopback today); `0600` secrets (as `token.py`
  already does); reliance on **VPS full-disk encryption**. App-level at-rest
  encryption is rejected — the server must hold plaintext to embed and serve, so
  it would guard only against offline disk theft that full-disk encryption
  already covers.
- A **durable send-side outbox** plus a **startup reconciliation sweep** (a
  mirror of `recovery/scanner.py`'s orphan logic) let an offline Mac eventually
  catch the server up; Ingest dedups by content-hash / chunk-id.
- `build_embedder` gains a CPU backend selected by config; the server's vector
  space is independent of any local index and the two never mix.
- Up to two MCP daemons can exist (Mac loopback for local Claude; VPS loopback
  for hermes) — one codebase, two modes, different bind/auth config.

## Considered and rejected

- **Tunnel back to the Mac's loopback daemon** (ADR 0001's anticipated path):
  zero replication, but cannot answer a query while the Mac is asleep — which is
  most of the time. Only viable for an always-on Mac.
- **Ship passages + vectors instead of `.md`:** the server needs a query
  embedder anyway, so this only adds a cross-runtime vector-space hazard for no
  gain.
- **File-sync transport (rsync / Syncthing over SSH / Tailscale):** fine for the
  author today, but needs SSH, keys, and an external daemon per user — a poor
  fit for "usable by other people." A self-contained authed HTTPS Ingest
  distributes cleanly, and the immutable, append-only Transcript stream keeps
  the push protocol small.
- **Multi-tenant service:** would make the author custodian of *others'* private
  transcripts (per-tenant isolation, accounts, quotas, compliance) to serve a
  1% feature. Self-host keeps each user the custodian of their own data.
- **Exposing the read/MCP endpoint publicly:** rejected for the write-only
  surface above.
