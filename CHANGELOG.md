# Changelog

All notable changes to huske will be documented in this file.

This project uses semantic versioning after the first public release.

## Unreleased

## 0.7.0 - 2026-06-03

### Added

- Off-device replication (opt-in; see
  `docs/adr/0004-off-device-huske-server.md` and `docs/server.md`). `huske serve`
  runs a single-tenant huske server on a box you control (e.g. a VPS): it
  receives finalized transcripts pushed from a recording Mac, stores and indexes
  them with a CPU (`fastembed`) embedder, and serves the existing `search`/`fetch`
  MCP over loopback to a co-located agent. When `sync_endpoint` is configured,
  `huske run` replicates each finalized transcript live — dependency-free and
  off the audio hot path, reconciling after the Mac has been offline — and
  `huske sync` backfills on demand. Only a write-only ingest endpoint is
  network-exposed; the read MCP stays loopback-only. Adds the `huske[server]`
  extra; the send side ships in the base install.
- huske now sets its OS process title via `setproctitle`, so it shows as
  `huske` (and `huske-whisper` / `huske-embed` / `huske-menubar` for its
  worker processes) in Activity Monitor, `ps`, and `top` instead of a bare
  Python interpreter. Best-effort and cosmetic — a silent no-op if
  `setproctitle` is unavailable, and it does not affect macOS privacy
  prompts or the recording indicator.

### Changed

- Python 3.14 is now supported: `requires-python` widened to
  `>=3.11,<3.15`, and the CI test matrix runs against 3.14.

## 0.6.0 - 2026-06-02

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
- **Local semantic search** (opt-in `huske[mcp]` extra). `huske index`
  builds or refreshes a local `sqlite-vec` passage store from transcripts.
  Each finalized transcript is embedded via `mlx-embeddings`
  (`multilingual-e5-base`) in an isolated subprocess so the audio drainer
  is never starved. `huske run` can continuously index during recording
  when `indexing_enabled = true` in config. See `docs/adr/0002` and
  `CONTEXT.md` for the Passage model.
- **`huske mcp` daemon** exposes `search` and `fetch` over a loopback HTTP
  MCP endpoint (bearer token + Origin/Host validation). Works with any MCP
  client (Claude Desktop, ChatGPT, etc.). See `docs/adr/0001`.
- `index_root`, `indexing_enabled`, `embedding_model`, `mcp_host`, and
  `mcp_port` config keys for the search subsystem.

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
