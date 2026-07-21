# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Shared tool-agnostic agent rules live in [AGENTS.md](AGENTS.md). Public
contribution rules live in [CONTRIBUTING.md](CONTRIBUTING.md).

## Project Shape

- Python CLI/TUI package in `huske/` (entry point: `huske.cli:app`, exposed as
  the `huske` console script — subcommands: `run`, `recover`, `doctor`,
  `devices`, `config`, and the opt-in `index` / `mcp` for local semantic
  search).
- Native macOS app in `macos/` (SwiftPM: `HuskeKit` library + `Huske` SwiftUI
  executable + XCTests). It is a shell over the engine's control socket and
  CLI — never re-implement pipeline logic there (ADR 0006). Build/test with
  `cd macos && swift build && swift test`; package with
  `macos/scripts/build-app.sh`. When you add snapshot fields or commands to
  `huske/ipc/protocol.py`, mirror them in
  `macos/Sources/HuskeKit/ControlProtocol.swift` (add-only, defaulted) and
  update both test suites.
- Unit and integration tests in `tests/`.
- Product specs and contracts in `specs/001-huske-recorder/`.
- Public contributor documentation in `README.md`, `CONTRIBUTING.md`, and
  `docs/`.

## Architecture

`huske run` is one orchestrator (`huske/run_loop.py`) wiring together four
modules that pass audio through a single pipeline:

1. **`capture/`** runs the mic (sounddevice / PortAudio thread) and system
   audio (Core Audio tap / ScreenCaptureKit on macOS) in parallel. A mixer
   thread drains both ring buffers every 50 ms and forwards each source to the
   sink *separately* (one WAV per source, frame-aligned on the mic clock — not
   summed on disk). It runs `capture/vad.py` (an adaptive energy VAD) on the
   combined signal once per tick and passes the speech verdict to the sink. If
   system audio fails, capture degrades to mic-only with a sticky warning.
2. **`chunker/rotator.py`** is that sink. It writes per-source WAVs under
   `audio_root/<session>/`. With `speech_gated` (default) it opens a chunk when
   speech starts and closes it after `silence_split_seconds` of silence or the
   `chunk_minutes` cap — so silent gaps aren't recorded; `speech_gated = false`
   restores fixed-interval rotation. Calls `on_finalized(AudioChunk)` per file.
3. **`transcribe/worker.py`** is a `multiprocessing` (spawn) subprocess. It
   builds a pluggable engine from `transcribe/engines/` — `parakeet` (default,
   via `parakeet-mlx`) or `whisper` (legacy `mlx-whisper`) — transcribes each
   per-source WAV, tags segments with their source, runs `transcribe/dedup.py`
   to drop mic echo of system audio, and renders the transcript. MLX inference
   releases the GIL but model loads / audio decode do not, so it must not run
   in the main process or it would starve the audio drainer. The orchestrator
   `submit()`s jobs and `poll_result()`s asynchronously. Audio is loaded +
   resampled to 16 kHz via `soundfile`+`soxr` (no ffmpeg).
4. **`transcribe/writer.py`** writes the Markdown transcript with YAML
   frontmatter under `output_root/YYYY-MM-DD/`. The contract for that
   filename and frontmatter is in
   `specs/001-huske-recorder/contracts/transcript-format.md` — keep them in sync.

`recovery/scanner.py` runs at startup and on `huske recover`: it scans
`audio_root/` for orphaned WAVs from a prior crash, submits the valid ones
to the worker, and moves invalid ones to `incomplete/`. `session.py` holds
a per-session lockfile that recovery uses to detect orphans.

`ui/live.py` is a Rich Live panel driven by `RenderState` (in `models.py`),
which the orchestrator updates at ~8 Hz. `--no-ui` swaps the live panel for
plain stdout. UI state is read-only from the UI's perspective — only the
orchestrator mutates it.

`config.py` merges YAML config + CLI overrides into a single immutable
`RuntimeConfig` (Pydantic). `paths.py` derives every filesystem path from
that config; do not hardcode paths elsewhere.

## Local search + MCP (opt-in `huske[mcp]` extra)

A separate subsystem makes transcripts semantically searchable from chat
models. It is off by default and adds no dependencies to the base install.

- `search/` is the engine: `parser.py` reads the on-disk `.md` contract (not
  in-memory state, so live indexing and backfill share one path),
  `windowing.py` groups runs into **Passages** (the retrieval unit — see
  `CONTEXT.md`), `embedder.py` wraps `mlx-embeddings` (multilingual-e5 on the
  same MLX/Metal stack as whisper) behind an interface with a dependency-free
  `HashingEmbedder` for tests, `store.py` is the `sqlite-vec` passage store
  (filtered KNN, model-mismatch refusal), and `indexer.py` ties them together.
- `search/worker.py` is an isolated embedding subprocess (mirrors the whisper
  worker) that `run_loop.py` feeds finalized transcript paths when
  `indexing_enabled`. Embedding must never run in the main process — same
  audio-drainer-starvation rule as whisper.
- `mcp/server.py` serves `search`/`fetch` (ChatGPT's contract, plus optional
  filters for Claude) over a loopback HTTP MCP endpoint with a bearer token +
  Origin/Host validation.

The three load-bearing decisions are recorded in `docs/adr/0001-0003`. Keep the
`sqlite-vec` schema and the model-versioning policy in `store.py` aligned with
ADR 0002. The base recording pipeline must not import this subsystem eagerly —
all heavy deps are lazily imported.

## Off-device server (opt-in `huske[server]` extra)

A second, separate opt-in subsystem replicates transcripts to a single-tenant
remote server (a VPS) so an always-on, co-located agent can query them while the
recording Mac is offline. Off by default; the send side adds no dependencies.
See `docs/adr/0004-off-device-huske-server.md` and `docs/server.md`.

- `sync/` is the **client** (base install, dependency-free): `outbox.py` is a
  durable stdlib-`sqlite3` record of what the server has acknowledged,
  `client.py` does `POST /ingest` over stdlib `urllib`, and `worker.py` is a
  background *thread* — not a subprocess, because network I/O releases the GIL
  and cannot starve the ~50 ms audio drainer — that pushes finalized transcripts
  off the hot path and reconciles on reconnect. `run_loop.py` feeds it from the
  same `_on_written` hook as the embed worker, inert unless `sync_endpoint` is
  set.
- `server/` is the **serve side** (`huske[server]`, on the VPS): `ingest.py` is
  the pure, hostile-input-validated store logic (strict `YYYY-MM-DD/<name>.md`
  rel-paths, sha256 verification, idempotent atomic writes), `app.py` is the
  write-token ASGI ingest endpoint, and `serve.py` wires them to the existing
  `Indexer`/`PassageStore` with a CPU (`fastembed`) embedder. The read side is
  the unchanged loopback `huske mcp`, run as a second process; both share the one
  `sqlite-vec` file via WAL.

Security invariant (ADR 0004): only the write-only ingest endpoint is
network-exposed (a TLS reverse proxy fronts it); the read MCP stays
loopback-only. The send transport ships in the base install — keep it
dependency-free; never import the heavy `huske.search` / `huske.mcp` paths from
`huske.sync`.

## Core Commands

```bash
# Install (editable, with dev extras)
uv pip install -e ".[dev]"

# Add the optional local-search / MCP extra (mlx-embeddings, sqlite-vec, mcp)
uv pip install -e ".[dev,mcp]"

# CI baseline — what PRs must pass
pytest tests/unit
pytest tests/integration/test_pipeline_no_whisper.py tests/integration/test_smoke.py

# Run a single test
pytest tests/unit/test_chunker.py::test_rotation_at_boundary_produces_finalized_chunk -xvs
```

Additional local quality checks:

```bash
ruff check .
mypy huske
```

Ruff and Mypy are configured but not CI gates yet; report existing baseline
failures instead of broad cleanup unless the task is specifically about lint or
typing.

Optional integration checks:

```bash
pytest tests/integration/test_system_audio.py
pytest tests/integration/test_real_whisper.py
```

## Privacy Rules

- Never commit generated audio, transcripts, logs, local config, model caches,
  credentials, or screenshots containing private content.
- Use synthetic audio and redacted paths in tests and examples.
- Treat `huske doctor` output as potentially sensitive.

## Implementation Notes

- Preserve the local architecture: capture, chunking, transcription, recovery,
  and UI are separate modules.
- Prefer focused patches and tests over broad refactors.
- Keep user-facing docs, examples, and specs aligned when behavior changes.

## Branching

Use the Gitflow naming rules in [AGENTS.md](AGENTS.md):

- Branch from `develop` for normal work and target PRs back to `develop`.
- Use `feat/<name>`, `fix/<name>`, `chore/<name>`, `docs/<name>`,
  `test/<name>`, `refactor/<name>`, `perf/<name>`, or `ci/<name>` for normal
  work.
- Use `release/vX.Y.Z` for release-prep branches from `develop`.
- Use `hotfix/<name>` only for urgent fixes branched from `main`; sync the fix
  back to `develop` after release.
- Keep branch slugs lowercase, ASCII, and kebab-case.

## Release Notes

The operational checklist is [docs/RELEASE_PLAYBOOK.md](docs/RELEASE_PLAYBOOK.md).
The deep reference is [docs/releasing.md](docs/releasing.md); the shared
agent summary is in [AGENTS.md](AGENTS.md).

Claude must not perform release operations unless the user explicitly asks for
release or release-prep work. When asked, prefer the scripts:

```bash
python scripts/release.py X.Y.Z              # opens release-prep PR -> develop
# (human merges)
python scripts/release-finalize.py X.Y.Z     # tag, GitHub release, back-merge PR
# (human merges back-merge)
python scripts/update-homebrew-tap.py X.Y.Z  # refreshes the brew tap formula
# (agent may run `brew install --build-from-source` + `brew test`; human reviews the diff and runs `git push`)
```

The scripts handle the version bump, CHANGELOG move, website updates
(`website/version.js` `HUSKE_VERSION` — the single string the whole site
reads — plus the README install-pin and a new `components-sections.jsx`
RELEASES entry with `tag: "latest"` rotation), and PR creation. Both the
package (`huske/__init__.py` reads `pyproject.toml`) and the website
(`website/version.js`) have a single source of truth — **do not hardcode
version strings anywhere else.** Every component renders `v{HUSKE_VERSION}`,
so the Nav, Footer, hero eyebrow, live-demo header, sample transcript
frontmatter, and "supported target" FAQ all move together; the historical
`RELEASES` timeline is the one intentional place older versions live.

**The release-prep script verifies the site itself**: after the bump it runs
`scan_stale_website_versions` and fails the release if any page still mentions
the previous version. Run the same sweep by hand any time:

```bash
python scripts/check-website-version.py        # checks the site against pyproject.toml
```

It looks **everywhere** on the site (and the README install-pin) for the
previous version — ignoring only the historical `RELEASES` timeline — and
confirms `HUSKE_VERSION`, the newest `RELEASES` entry, and the install-pin all
match `pyproject.toml`. A non-zero exit lists every offending `file:line`.

Still confirm by hand each release:

- **Supported Python versions** live in `HUSKE_PYTHONS` (`website/version.js`)
  and must match `requires-python` in `pyproject.toml`; they render in the
  hero install foot, install-section sub copy, and docs facts list.
- **Any other shipped-behavior copy** (commands, flags, defaults, config keys,
  feature claims) touched by the release must be reflected on the site.
- After the `RELEASES` entry is added, load the page
  (`python -m http.server --directory website`) to confirm it renders.

When the playbook does not fit (manual debugging, partial release, etc.),
fall back to the steps in [docs/releasing.md](docs/releasing.md).
- Right after the promotion PR merges to `main`, back-merge `main` into
  `develop` so the new merge commit and tag are reachable from `develop`.
  Use a temp branch (`chore/sync-main-after-vX.Y.Z` from `develop`, with
  `git merge origin/main --no-ff` applied locally), never `head=main` —
  otherwise `delete_branch_on_merge: true` auto-deletes `main`. Merge the
  resulting PR with **"Create a merge commit"**, not "Squash and merge",
  or `main`'s tip is not added to `develop`'s ancestry and the "out of
  date" warning persists. The same applies after a hotfix.
- Tag only the merged `main` commit with `vX.Y.Z`.
- Create GitHub releases only from existing tags, using `gh release create`
  with `--verify-tag`.
- Let `.github/workflows/release.yml` build GitHub release assets and publish
  PyPI through trusted publishing. Do not use PyPI API tokens.
- After PyPI is live, update the Homebrew tap in
  `tiagomoraes/homebrew-huske`. Preserve its custom formula structure: most
  Python dependencies are pinned wheels, and PyAV (`av`) is built from sdist
  against Homebrew `ffmpeg`.
- Validate tap changes with `brew style`, `brew audit --strict --online`,
  `brew install --build-from-source`, and `brew test`.
- Never push directly to `main` or `develop`, never force-push release tags, and
  never move a published tag.
