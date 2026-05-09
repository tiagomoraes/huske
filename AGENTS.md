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

## Gitflow and Branch Names

This repository follows a lightweight Gitflow model:

- `main` is the stable release branch.
- `develop` is the integration branch and default PR target.
- Work branches are created from `develop` unless they are release or hotfix
  branches.
- Release branches are created from `develop`.
- Hotfix branches are created from `main` and must be merged back into
  `develop` after the patch release.

Branch names must be lowercase ASCII, use `/` after the type prefix, and use
kebab-case for the descriptive slug. Do not use spaces, underscores, personal
names, or vague slugs like `changes` or `updates`.

Use these prefixes:

- `feat/<short-feature-name>` for new user-facing behavior.
- `fix/<short-bug-name>` for bug fixes targeting `develop`.
- `hotfix/<short-critical-fix>` for urgent production/release fixes from
  `main`.
- `chore/<short-maintenance-name>` for maintenance tasks.
- `docs/<short-doc-name>` for documentation-only changes.
- `test/<short-test-name>` for test-only changes.
- `refactor/<short-refactor-name>` for behavior-preserving code changes.
- `perf/<short-performance-name>` for performance improvements.
- `ci/<short-ci-name>` for CI and GitHub Actions changes.
- `release/vX.Y.Z` for release-prep branches.

Examples:

```text
feat/configurable-audio-retention
fix/recovery-empty-session-cleanup
hotfix/transcript-write-crash
chore/update-dependencies
docs/release-process
test/chunker-boundary-cases
refactor/transcription-worker-queue
perf/audio-buffer-drain
ci/cache-python-deps
release/v0.2.0
```

Automation-owned prefixes such as `dependabot/...` are allowed for their tools.
Agents should use the Gitflow prefixes above unless the user explicitly asks for
a different branch name.

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
`test_real_whisper.py` downloads and runs the `tiny` mlx-whisper model
(Apple Silicon only — skipped on other platforms).

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
- Work branches use the Gitflow naming rules above.
- Tags must use `vX.Y.Z`.
- Public release tags must point at `main`, never at `develop`.

Agent-safe release workflow:

1. Prepare a release branch from an up-to-date `develop`.
2. Update `pyproject.toml` version and `CHANGELOG.md`.
3. Update the website release timeline and version strings: add a new entry
   to the `RELEASES` array in `website/components-sections.jsx` (move the
   `tag: "latest"` to the new entry), and bump the hardcoded version string
   in `website/components-shell.jsx` (both the Nav `<span className="ver">`
   and the Footer `huske vX.Y.Z` line). Mirror the `CHANGELOG.md` entry
   content as JSX `items` on the new release.
4. Run the CI baseline and any relevant manual checks.
5. Open a release-prep PR back to `develop`.
6. After that PR merges, create a promotion PR from `develop` to `main`.
7. After the promotion PR merges, tag the resulting `main` commit.
8. Create the GitHub release from the existing tag using `--verify-tag`.
9. Let `.github/workflows/release.yml` publish GitHub assets and PyPI through
   trusted publishing. Pushing the release commit to `main` also redeploys
   the website via `.github/workflows/pages.yml` when `website/` changes.
10. Update the Homebrew tap at `tiagomoraes/homebrew-huske` after PyPI is live.

Important guardrails:

- Never push directly to `main` or `develop`.
- Never force-push `main`, `develop`, or release tags.
- Never create a release with a tag that has not been verified locally and on
  GitHub.
- Never use `gh release create` without `--verify-tag` for this repository.
  The default branch is `develop`, so an implicit tag could target the wrong
  branch.
- Never use PyPI passwords or API tokens for releases. PyPI uses GitHub
  Actions trusted publishing with the `pypi` GitHub environment.
- Do not move or delete a published release tag. Fix forward with a patch
  release instead.
- Do not replace the Homebrew formula's custom Python installation with plain
  `virtualenv_install_with_resources`. The tap intentionally pins platform
  wheels and builds PyAV (`av`) from sdist against Homebrew `ffmpeg`.
- Validate Homebrew changes with `brew style`, `brew audit --strict --online`,
  `brew install --build-from-source`, and `brew test`.

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

# After PyPI is live:
brew tap tiagomoraes/huske
cd "$(brew --repo tiagomoraes/huske)"
brew style Formula/huske.rb
brew audit --strict --online tiagomoraes/huske/huske
brew install --build-from-source tiagomoraes/huske/huske
brew test tiagomoraes/huske/huske
```
