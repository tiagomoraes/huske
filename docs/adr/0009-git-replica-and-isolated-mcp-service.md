---
status: accepted
date: 2026-07-30
supersedes: [0001, 0002, 0003, 0004, 0008]
---

# Git replica and isolated MCP service

## Context

The recording application previously owned three unrelated responsibilities:
recording/transcription, HTTP replication to a custom ingest endpoint, and an
optional MCP/search/OAuth server. This made the app installation heavier, kept
network read code beside private on-device transcripts, and made the always-on
deployment repeat much of the Mac package.

The desired topology has a simpler trust boundary:

1. the Mac writes canonical, immutable transcript Markdown;
2. a standard cloud storage mechanism carries those files;
3. an independent, Linux-oriented service maintains the read replica and MCP.

The service must remain useful on a 1 vCPU / 512 MB VPS. Webhooks may reduce
latency but cannot be the sole consistency mechanism because delivery is
best-effort.

## Decision

### Recording application

The app only publishes transcript files. Git is the first storage provider and
GitHub is the documented host:

- `sync_enabled`, `sync_remote`, and `sync_branch` configure publication;
- a dedicated managed checkout under `sync_root` contains
  `transcripts/YYYY-MM-DD/*.md`;
- the worker pulls/rebases before copying, commits append-only files, and pushes
  through the user's existing SSH agent or Git credential helper;
- Huske stores no GitHub token;
- Git commits replace the custom SQLite/HTTP outbox. A commit that could not be
  pushed remains durable in the checkout;
- a different file at an established transcript path is a hard conflict. The
  publisher never overwrites it;
- audio, screenshots, logs, config, credentials, and generated local state are
  excluded.

The app no longer exposes `huske mcp`, `huske serve`, `huske index`,
`huske setup`, or `huske connect`, and no MCP dependency ships in its extras.

### VPS service

`services/huske_mcp` is an independent Python distribution and executable:

- `huske-mcp` is installed, configured, upgraded, and supervised separately;
- its Git checkout is read-only from the service's perspective;
- polling is the correctness path; a signed GitHub push webhook only wakes the
  poller early;
- the index is a separate SQLite database in WAL mode, outside the checkout;
- indexing is incremental by transcript SHA-256 and removes rows whose source
  file disappeared;
- MCP is stateless Streamable HTTP with `search`, `fetch`, `recap`, `overview`,
  and `sync_status`;
- the service refuses to start without a bearer token, even on loopback, and
  validates proxy `Host` values. TLS terminates at a reverse proxy or private
  overlay network.

### Resource profiles

`tiny` is the default and supported 512 MB profile:

- SQLite FTS5 with Unicode tokenization;
- 8 MB page cache, 32 MB mmap ceiling, one uvicorn worker, one poll thread;
- no resident embedding or language model;
- exact date, source, and session filters plus chronological retrieval.

`semantic` is an explicit opt-in:

- Model2Vec generates static dense embeddings;
- search combines FTS and dense ranks with reciprocal-rank fusion;
- vectors are read in bounded batches rather than loading the corpus into RAM;
- the multilingual default needs a larger machine. The service documents at
  least 1 GB or a smaller model.

This is an intentional honesty boundary: the 512 MB profile returns high-quality
lexical/time retrieval and never labels it semantic. Real dense semantics costs
memory and is selectable rather than silently exhausting the VPS.

## Consequences

- The recording hot path has no server SDK, OAuth database, vector extension, or
  embedding subprocess.
- GitHub provides durable history, encryption in transit, access controls, and
  auditability without a Huske-specific ingest protocol.
- A private repository now contains plaintext transcripts and must be treated as
  sensitive data.
- Agents that require OAuth and cannot send a bearer header need an external
  identity-aware proxy; the tiny service does not embed an authorization server.
- Git is the first provider, not the abstraction itself. A future object-storage
  publisher can implement the same immutable-file contract without changing
  transcription or MCP indexing.
- Existing `sync_endpoint`, ingest, MCP, connector, and local-index config keys
  are ignored on read and removed on the next config write.
