# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Shared tool-agnostic agent rules live in [AGENTS.md](AGENTS.md). Public
contribution rules live in [CONTRIBUTING.md](CONTRIBUTING.md).

## Project Shape

- Python CLI/TUI package in `huske/` (entry point: `huske.cli:app`, exposed as
  the `huske` console script — subcommands: `run`, `recover`, `doctor`).
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

## Core Commands

```bash
# Install (editable, with dev extras)
uv pip install -e ".[dev]"

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

## Release Notes

The canonical release process is [docs/releasing.md](docs/releasing.md); the
shared agent summary is in [AGENTS.md](AGENTS.md).

Claude must not perform release operations unless the user explicitly asks for
release or release-prep work. When asked:

- Start release-prep work from an up-to-date `develop`.
- Open release-prep PRs back to `develop`.
- Promote releases through a PR from `develop` to `main`.
- Tag only the merged `main` commit with `vX.Y.Z`.
- Create GitHub releases only from existing tags, using `gh release create`
  with `--verify-tag`.
- Never push directly to `main` or `develop`, never force-push release tags, and
  never move a published tag.
