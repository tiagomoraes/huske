# huske Development Guidelines

This file gives Claude-specific guidance for this repository. Shared
tool-agnostic agent rules live in [AGENTS.md](AGENTS.md). Public contribution
rules live in [CONTRIBUTING.md](CONTRIBUTING.md).

## Project Shape

- Python CLI/TUI package in `huske/`.
- Unit and integration tests in `tests/`.
- Product specs and contracts in `specs/001-huske-recorder/`.
- Public contributor documentation in `README.md`, `CONTRIBUTING.md`, and
  `docs/`.

## Core Commands

```bash
pytest tests/unit
pytest tests/integration/test_pipeline_no_whisper.py tests/integration/test_smoke.py
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
