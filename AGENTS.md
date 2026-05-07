# Agent Instructions

These instructions apply to AI coding agents working in this repository. They
are intentionally tool-agnostic. Tool-specific files, such as `CLAUDE.md`, may
add local workflow notes, but this file is the shared baseline.

## Project Map

- `huske/`: Python CLI/TUI package.
- `tests/`: unit and integration tests.
- `examples/`: example user configuration.
- `specs/`: feature specs, contracts, and planning artifacts.
- `docs/`: maintainer and contributor documentation.

## Default Work Rules

- Keep changes focused on the user's request.
- Prefer existing architecture and helpers over new abstractions.
- Do not commit generated audio, transcripts, logs, local config, model caches,
  credentials, or screenshots containing private content.
- Use synthetic audio and redacted paths in tests and examples.
- Treat `huske doctor` output as potentially sensitive.

## Checks

Current CI baseline:

```bash
pytest tests/unit
pytest tests/integration/test_pipeline_no_whisper.py tests/integration/test_smoke.py
```

Additional local quality checks:

```bash
ruff check .
mypy huske
```

Ruff and Mypy are configured but are not CI gates yet. Report existing baseline
failures instead of broad cleanup unless the task is specifically about lint or
typing.

Optional integration checks:

```bash
pytest tests/integration/test_system_audio.py
pytest tests/integration/test_real_whisper.py
```

`test_system_audio.py` needs macOS Screen Recording permission.
`test_real_whisper.py` downloads and runs the `tiny` faster-whisper model.

## Release Process for Agents

Do not perform release operations unless the user explicitly asks for a release
or release-prep work. Releases are sensitive because they move code from
`develop` to `main`, create public release tags, and publish GitHub release
notes.

The full maintainer playbook is [docs/releasing.md](docs/releasing.md). Follow
that document as the source of truth.

Release branch model:

- `develop` is the integration branch and the default PR target.
- `main` is the stable release branch.
- Tags must use `vX.Y.Z`.
- Public release tags must point at `main`, never at `develop`.

Agent-safe release workflow:

1. Prepare a release branch from an up-to-date `develop`.
2. Update `pyproject.toml` version and `CHANGELOG.md`.
3. Run the CI baseline and any relevant manual checks.
4. Open a release-prep PR back to `develop`.
5. After that PR merges, create a promotion PR from `develop` to `main`.
6. After the promotion PR merges, tag the resulting `main` commit.
7. Create the GitHub release from the existing tag using `--verify-tag`.

Important guardrails:

- Never push directly to `main` or `develop`.
- Never force-push `main`, `develop`, or release tags.
- Never create a release with a tag that has not been verified locally and on
  GitHub.
- Never use `gh release create` without `--verify-tag` for this repository.
  The default branch is `develop`, so an implicit tag could target the wrong
  branch.
- Do not move or delete a published release tag. Fix forward with a patch
  release instead.

Reference commands:

```bash
git fetch origin --prune --tags
git switch develop
git pull --ff-only
git switch -c release/vX.Y.Z

# After release-prep PR merges to develop:
gh pr create --repo tiagomoraes/huske --base main --head develop \
  --title "release: vX.Y.Z" \
  --body "Promotes develop to main for huske vX.Y.Z."

# After promotion PR merges:
git switch main
git pull --ff-only
git tag -a vX.Y.Z -m "huske vX.Y.Z"
git push origin vX.Y.Z
gh release create vX.Y.Z --repo tiagomoraes/huske --verify-tag \
  --title "huske vX.Y.Z" --notes-file /tmp/huske-release-notes.md
```
