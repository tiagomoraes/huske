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

## Amendment (2026-11) — Huske-owned updates, remote deletions, repository docs

"Immutable" was the wrong word for the transcript tree. Distillation
(ADR 0005) rewrites the canonical `.md` in place after the transcript is
written, and sync publishes it as soon as it is written, so the raw version
almost always reached the repository first. The polished rewrite then looked
like a "different file at an established path": a hard, non-retryable
conflict. Because the copy loop aborted at the first conflict, every
transcript recorded afterwards stopped publishing too.

The rule is now about *ownership*, not immutability:

- The publisher keeps a ledger of the content it last published for each
  path. The ledger lives in the managed checkout's `.git` directory and is
  never committed.
- A repository copy that matches the ledger is Huske's own, and is replaced
  when the local transcript changes. So is a copy that matches the raw
  `<name>.asr.txt` snapshot distillation keeps, which heals checkouts that
  predate the ledger.
- Anything else at that path was written by someone else. It is reported as a
  conflict and never overwritten, and it no longer blocks other transcripts.
- A path Huske published that later disappears from the repository was
  deleted there on purpose. It is not published again. Git history still holds
  earlier versions; deletion is not a purge.
- `huske sync --republish <path>` is the explicit override for both cases.

Housekeeping that made failures unrecoverable from the app is now automatic:

- One sync runs per checkout across processes. The engine's worker and
  `huske sync` from the app share an advisory lock, and a stale `index.lock`
  is cleared.
- Pointing sync at another repository moves the old checkout aside instead of
  refusing.
- Retryable failures are retried on a capped backoff for the whole session,
  instead of stopping after six attempts.
- Git errors are classified from every stderr line. The last line of an SSH
  failure is boilerplate.
- The engine reports the last problem as a sticky `sync` warning.

The repository root also carries a Huske-managed `README.md` and `AGENTS.md`,
so an agent connected through its own GitHub integration can navigate the
archive. A file without Huske's marker line is never overwritten. The VPS
service reads only `transcripts/`, and its index already re-indexes a path
whose SHA-256 changed.

## Amendment (2026-11) — Connect GitHub with the Huske Sync app

Setting up Git over SSH was where new users failed. They needed a key on
GitHub, an agent that could unlock it without a terminal, and a trusted host
key, and every one of those failures surfaced the same opaque Git message. It
was also more access than the job needs: an account SSH key can push to every
repository the user can write to. The research behind this is in
`docs/research/transcript-sync-options.md`.

Sync can now authenticate with **Huske Sync**, a GitHub App registered for
the project. This is `sync_auth = "github-app"`; the default stays
`sync_auth = "git"`, which uses the Mac's own Git sign-in and stores nothing,
so existing setups are unchanged.

- **Least privilege.** The app requests only repository *Contents*
  (read/write) and the mandatory *Metadata* (read). It has no
  *Administration* (it cannot delete or reconfigure repositories), no
  repository creation, and no webhooks. The user creates the private
  repository from a prefilled form and shares only it with the app ("Only
  select repositories").
- **No secret.** Sign-in is the OAuth device flow. Huske is a public client,
  and GitHub issues and refreshes the user access token without a client
  secret. Access tokens last 8 hours; refresh tokens rotate and last about six
  months.
- **The engine owns the sign-in** (`huske sync login | logout | status |
  repos | use`). Huske.app renders the same flow from their `--json` output
  (ADR 0006).
- **Storage.** The token set lives in the macOS login Keychain, written
  through `/usr/bin/security -i` over standard input, so the secret never
  appears in a process argument. Items created by `security` are readable by
  `security` without a prompt, which is what lets the launchd engine use them.
  `HUSKE_SYNC_KEYCHAIN` points at a throwaway keychain for development.
- **Git** receives the token only through the environment of each command
  (`GIT_CONFIG_*`), through a one-shot credential helper. Every other
  helper is reset for that command, including github.com-specific ones such as
  `gh auth setup-git` writes. The token is never written to `.git/config`,
  logs, or Huske's configuration.
- **Renewal under the sync lock.** A refresh invalidates the previous access
  token immediately (observed against GitHub), so renewal happens only while
  holding the cross-process sync lock. That guarantees no other Huske process
  is mid-push with the old token.
- `huske sync use` refuses a public repository, and a repository not shared
  with the app.

Consequences:

- A leaked access token reaches the shared repository for at most 8 hours. A
  leaked refresh token is renewable until it is revoked
  (github.com/settings/apps/authorizations) or the app is uninstalled.
- The project keeps the app registration. The client ID is public and lives in
  `huske/sync/github.py`; forks point at their own app with
  `HUSKE_GITHUB_APP_CLIENT_ID` and `HUSKE_GITHUB_APP_SLUG`. The app must be
  made public before a release that ships this flow.
