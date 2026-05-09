# Changelog

All notable changes to huske will be documented in this file.

This project uses semantic versioning after the first public release.

## Unreleased

### Changed

- Release process collapses into three scripts under `scripts/`:
  `release.py`, `release-finalize.py`, and `update-homebrew-tap.py`. The
  short operational checklist is `docs/RELEASE_PLAYBOOK.md`;
  `docs/releasing.md` remains as the deep reference.
- `huske/__init__.py` now reads the version from `pyproject.toml` when
  the package source is adjacent (dev checkout / editable install) and
  falls back to `importlib.metadata` for installed wheels. The two
  hardcoded versions could no longer drift the way `0.3.1` had to be
  hotfixed for.

### Added

- `.github/workflows/back-merge.yml` automatically opens the
  `chore/sync-main-after-vX.Y.Z` (or `chore/sync-main-hotfix-…`) PR when
  a `release: v*` / `hotfix:*` PR merges into `main`, so the back-merge
  step no longer relies on the maintainer remembering to open it.

## 0.5.0 - 2026-05-09

### Added

- `huske autostart` subcommand group to manage a macOS LaunchAgent that runs
  `huske run --no-ui` at every login. Verbs: `install`, `uninstall`, `status`,
  `start`, `stop`. The plist lives at `~/Library/LaunchAgents/me.huske.plist`
  and stdout/stderr are appended to `~/Library/Logs/huske/agent.{out,err}.log`.
  Default restart policy is "restart on crash only"
  (`KeepAlive={SuccessfulExit:false}`). macOS-only; commands exit with a
  friendly error on other platforms.

## 0.4.0 - 2026-05-09

### Added

- Live UI controls panel. Press `?` in the live UI to open an overlay; inside,
  `p` toggles pause/resume of audio recording, `s` toggles periodic
  screenshots, `q` triggers a graceful stop, and `Esc` closes the overlay.
  Pausing finalizes the current partial chunk and stops writing audio until
  you resume. Toggling screenshots takes effect immediately, using the
  configured screenshots directory and interval. The screenshot interval
  must now be at least 1 second.

### Changed

- Group adjacent transcript segments from the same source under a single
  timestamp range. Long same-source runs are broken up after roughly 90 s so
  monologues do not collapse every interior timestamp, and empty or missing
  source segments are left ungrouped instead of silently merging with
  neighbors.

### Fixed

- Suppress whisper hallucinations on quiet input. Compute a per-source noise
  floor from each chunk's WAV at ingest and drop any segment whose audio
  window sits below an RMS/peak gate calibrated to that floor (with
  conservative absolute lower bounds). Also pass
  `condition_on_previous_text=False` to mlx-whisper so a hallucinated segment
  can no longer anchor the next chunk's decoding. Fails open on WAV read
  errors so a broken file never silently swallows a real transcript.

## 0.3.1 - 2026-05-08

### Fixed

- Corrected the runtime version reported by `huske --version`, `huske doctor`,
  update checks, transcript metadata, and the TUI after the `0.3.0` package
  metadata shipped with `huske.__version__` still set to `0.2.0`.

## 0.3.0 - 2026-05-08

### Changed

- Switched the transcription engine from `faster-whisper` (CTranslate2, CPU
  only on Apple Silicon) to `mlx-whisper` (Apple MLX, runs on the M-series
  GPU). On a Mac this is roughly 5–7× faster and removes the long
  first-load hang we hit with the `small` model. Existing `model` /
  `compute_type` / `device` keys in `~/.config/huske/config.toml` are still
  accepted: model names map to the `mlx-community/whisper-<size>-mlx` repos,
  `compute_type = "float32"` opts out of fp16, and `device` is ignored
  (MLX always runs on the Apple GPU). The transcript `model:` field now
  reads `mlx-whisper:<size>` instead of `faster-whisper:<size>`.
  Apple Silicon only — Intel Macs are no longer supported.
- Added per-source transcript segments for mic and system audio, with system
  WAV padding so segment timestamps map back to the wall-clock session time.

### Added

- Added the Core Audio process-tap backend for system audio capture.
- Optional periodic screenshots. `huske run --screenshots` captures a JPEG
  of every attached display every 10 seconds (`--screenshot-interval`
  configurable, default 10 s). Files land at
  `~/huske/screenshots/YYYY-MM-DD/<session_id>/HHMMSS_dN.jpg` so multimodal
  LLMs can correlate them with the day's transcripts. Capture uses the
  built-in macOS `screencapture` tool — no new Python dependency, and it
  reuses the existing Screen Recording permission. Off by default.

## 0.2.0 - 2026-05-07

### Added

- Update check on startup. Prints a stderr banner when a newer release is on
  PyPI, with the upgrade command tailored to the install method
  (`uv tool upgrade huske`, `pipx upgrade huske`, or `brew upgrade huske`).
  The check is cached for 24 h, runs in a background thread, is silent for
  editable installs and non-TTY stderr, and can be disabled with
  `HUSKE_NO_UPDATE_CHECK=1`.

## 0.1.0

### Added

- Initial always-on macOS terminal recorder.
- Microphone and system audio capture.
- Local transcription through faster-whisper.
- Day-organized Markdown transcript output.
- Recovery for orphaned audio chunks.
- Rich terminal UI and setup doctor.
- Open source project structure: license, contribution guide, code of conduct,
  security policy, support guide, issue templates, PR template, and CI.
