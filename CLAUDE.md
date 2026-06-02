# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Shared tool-agnostic agent rules live in [AGENTS.md](AGENTS.md). Public
contribution rules live in [CONTRIBUTING.md](CONTRIBUTING.md).

## Project Shape

- Python CLI/TUI package in `huske/` (entry point: `huske.cli:app`, exposed as
  the `huske` console script — subcommands: `run`, `recover`, `doctor`, and the
  opt-in `index` / `mcp` for local semantic search).
- Unit and integration tests in `tests/`.
- Product specs and contracts in `specs/001-huske-recorder/`.
- Public contributor documentation in `README.md`, `CONTRIBUTING.md`, and
  `docs/`.

## Architecture

`huske run` is one orchestrator (`huske/run_loop.py`) wiring together four
modules that pass audio through a single pipeline:

1. **`capture/`** runs the mic (sounddevice / PortAudio thread) and system
   audio (ScreenCaptureKit on macOS) in parallel. A mixer thread sums both
   ring buffers into a mono float32 stream and forwards 50 ms blocks to the
   sink. If system audio fails, capture degrades to mic-only with a sticky
   warning.
2. **`chunker/rotator.py`** is that sink. It writes blocks to a WAV file under
   `audio_root/<session>/`, rotates on the configured chunk boundary (default
   15 min), and calls `on_finalized(AudioChunk)` per finalized file.
3. **`transcribe/worker.py`** is a `multiprocessing` (spawn) subprocess.
   Faster-whisper holds the GIL during inference, so it must not run in the
   main process or it would starve the audio drainer. The orchestrator
   `submit()`s jobs and `poll_result()`s asynchronously.
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
# (human runs `brew install --build-from-source && brew test && git push`)
```

The scripts handle the version bump, CHANGELOG move, website updates
(`components-shell.jsx` Nav/Footer + `components-sections.jsx` RELEASES
with `tag: "latest"` rotation), and PR creation. `huske/__init__.py`
reads the version from `pyproject.toml` so there is only one source of
truth — do not hardcode version strings.

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
