# Contributing to huske

Thanks for helping improve huske. This project records microphone and system
audio, so contribution quality includes privacy hygiene as much as code quality.

## Code of conduct

Participating in this project means following the project
[Code of Conduct](CODE_OF_CONDUCT.md).

## Before opening an issue

1. Search existing issues and pull requests for the same report or proposal.
2. Run `huske doctor` and include only non-sensitive results.
3. Check [README.md](README.md), [docs/development.md](docs/development.md),
   and the feature specs under [specs/](specs/).
4. Remove names, meeting details, raw transcript text, audio files, paths that
   expose private information, and any credentials before posting.

Use the issue templates when available:

- Bug report: reproducible failures, crashes, bad transcripts, device problems.
- Feature request: new behavior, platform support, workflow improvements.
- Documentation: unclear, missing, or outdated docs.
- Security or privacy vulnerability: follow [SECURITY.md](SECURITY.md) instead
  of opening a public issue.

## Finding work to pick up

Good first issues should be small, reproducible, and covered by a focused test
or documentation change. Useful labels for maintainers are documented in
[docs/issue-triage.md](docs/issue-triage.md). If an issue is not clearly scoped,
ask for clarification before starting implementation.

## Development setup

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -e ".[dev]"
```

For macOS capture checks, run:

```bash
huske doctor
```

For the current CI baseline, run:

```bash
pytest tests/unit
pytest tests/integration/test_pipeline_no_whisper.py tests/integration/test_smoke.py
```

Ruff and Mypy configuration is present for local quality work, but they are not
CI gates yet while the 0.1 codebase is being stabilized. Integration tests are
documented in [docs/development.md](docs/development.md); some need macOS
permissions or download a Whisper model.

## Pull requests

1. Open an issue first for non-trivial behavior changes.
2. Keep PRs focused on one concern.
3. Add or update tests when behavior changes.
4. Update README, docs, examples, or specs when user-facing behavior changes.
5. Do not commit generated audio, transcripts, logs, local config, model caches,
   credentials, or screenshots containing private content.
6. Link the relevant issue in the PR description.
7. Fill out the PR checklist and include the exact checks you ran.

Commit messages should be short and descriptive. Existing history uses a simple
conventional style such as `feat:`, `fix:`, `docs:`, `test:`, and `chore:`.

## License of contributions

By submitting a contribution, you agree that your contribution is licensed under
the same [MIT License](LICENSE) as the project.
