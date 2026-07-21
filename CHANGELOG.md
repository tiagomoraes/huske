# Changelog

All notable changes to huske will be documented in this file.

This project uses semantic versioning after the first public release.

## Unreleased

### Added

- **Native macOS app.** A SwiftUI app (`macos/`, built with
  `macos/scripts/build-app.sh` → `Huske.app`) that drives the same engine as
  the terminal UI: start/stop/pause with live mic + system level meters,
  chunk/queue state and a live activity feed, mid-session screenshot and
  distillation toggles, live microphone switching, a day-grouped transcript
  browser with per-run rendering and full-text search, a Doctor pane, an
  engine-validated Configuration editor, a menu bar extra, and crash
  recovery. It attaches to sessions started by the TUI or the login
  LaunchAgent, and quitting while recording drains gracefully like Ctrl+C.
  See `docs/macos-app.md` and `docs/adr/0006-native-macos-app.md`.
- **Richer control protocol (v2) for external UIs.** `huske run` gained
  `--control-socket PATH` to serve its JSON-line control protocol at an
  explicit socket for an external UI (no bundled menu bar helper). Snapshots
  now carry peak levels, chunk/session timing, warnings, recent events,
  output paths, and the active input device — all backward compatible — and
  clients can switch the microphone (`set_input_device`) and request the
  device list over the socket.
- **`huske config show|set|unset`** — inspect and edit
  `~/.config/huske/config.toml` from the command line with the same
  validation as `huske run` (`--json` output for tooling), and
  **`huske devices [--json]`** — list microphone inputs and how the
  configured one resolves.

## 0.10.0 - 2026-06-29

### Added

- **Toggle distillation live from the TUI and menu bar.** Distillation no longer
  has to be chosen at launch — press `d` in the live UI's `?` controls overlay,
  or pick **Toggle distillation** from the macOS menu-bar dropdown, to turn it on
  or off for the running session. Turning it on first runs the same readiness
  check as `huske doctor` (local LLM daemon reachable + model pulled) and warns
  with a fix-it hint if it is not ready; both surfaces show the current on/off
  state. The toggle is session-only — set `distill_enabled` in config to make it
  the default.

## 0.9.1 - 2026-06-28

### Fixed

- **Speaker-bleed alignment.** The echo canceller now aligns the mic and system
  channels correctly when the saved system reference arrives *late* relative to
  the mic echo (the two are captured on independent clocks) and when a chunk
  opens with only the local speaker before the first system audio — cases the
  0.9.0 delay estimator missed, leaving the bleed in the transcript. The delay
  search now scans for a jointly-energetic window, allows a negative lag, and
  widens to 2 s.
- **Residual-bleed backstop.** When the mic's transcript of system audio is too
  garbled to match by text, an audio-coherence check now flags and drops the mic
  segment if it is acoustically a copy of the near-simultaneous system channel,
  so bleed no longer survives text de-dup. Your own voice (incoherent with the
  system) is never dropped.

## 0.9.0 - 2026-06-24

### Added

- **Parakeet transcription engine, now the default.** huske transcribes with
  NVIDIA Parakeet (`parakeet-tdt-0.6b-v3`) via `parakeet-mlx` on the Apple
  Silicon GPU. As a transducer it emits nothing on silence/noise instead of
  hallucinating repeated filler ("e aí e aí…", "sports sports…") the way Whisper
  does, and it is multilingual with automatic language detection (~25 languages,
  Portuguese included). The transcription backend is now pluggable
  (`asr_engine = "parakeet" | "whisper"`, default `parakeet`); `--asr-engine
  whisper` keeps the legacy mlx-whisper path, paired with its energy gate.
  Audio is loaded and resampled to 16 kHz with `soundfile` + `soxr`, dropping
  transcription's hidden dependency on the `ffmpeg` CLI.
- **Speech-gated, silence-split segmentation** (`speech_gated`, on by default).
  Chunks now open when speech is first heard and close after a real pause
  (`silence_split_seconds`, default 60 s) or at the `chunk_minutes` cap (now a
  safety cap, default 30 min). Silence between chunks is no longer recorded, so
  a quiet stretch produces no large near-empty file, and a conversation is no
  longer cut mid-sentence at a fixed 15-minute tick. `--no-speech-gated`
  restores the legacy fixed-interval rotation. New flags: `--speech-gated /
  --no-speech-gated`, `--silence-split`.
- **Speaker-bleed removal** when recording mic + system on speakers (no
  headphones), in two stages:
  - **Echo suppression** (`echo_cancel`, default on) — coherence-based
    suppression attenuates the mic content that is coherent with the clean
    system channel (the bleed) before transcription. It is self-gating (no
    coherence with headphones → the mic is untouched) and cannot remove the
    local voice (incoherent with the system), so double-talk is preserved.
    Sample-precise acoustic echo *cancellation* was investigated and simulated
    but is infeasible here: the mic (PortAudio) and system (Core Audio tap) are
    captured on independent clocks, so their alignment jitters and there is no
    stable echo path to subtract (measured negative ERLE on real recordings).
    Coherence suppression is robust to that jitter. `--no-echo-cancel` disables it.
  - **Cross-channel dedup** (`echo_dedup`, default `drop`) — the reliable
    remover: a mic run that echoes a near-simultaneous system run is dropped,
    now matching **partial fragments** (a verbatim chunk of a system line), not
    only whole-line duplicates, via token-set similarity + contiguous-run
    containment + a temporal gate. One-way, so the local voice and the clean
    system line are never removed. `--echo-dedup drop|annotate|off`.

### Changed

- `chunk_minutes` is now a maximum-length safety cap rather than the usual chunk
  boundary, and its default rose from 15 to 30 minutes (see speech-gated
  segmentation above). For speech-gated chunks, `duration_seconds` in the
  frontmatter reports the recorded length and such chunks are no longer flagged
  `incomplete`. The `model` frontmatter value is now e.g.
  `parakeet:tdt-0.6b-v3`. See `specs/001-huske-recorder/contracts/transcript-format.md`.
- The auto-generated `~/huske/transcripts/README.md` was rewritten as a proper
  entry point for an LLM agent: it explains the speech-gated boundaries, the
  corrected frontmatter schema, and what the `mic`/`system` source tags mean
  (you/the room vs. audio played by the computer), with echo removed so system
  audio isn't double-counted on the mic side.

## 0.8.2 - 2026-06-10

### Changed

- `whisper_idle_unload` now defaults to **on**. The transcription worker drops
  the Whisper model after `whisper_idle_unload_seconds` of inactivity (default
  120 s) and reloads it from the local cache on the next chunk, so huske idles
  at a few hundred MB instead of holding ~150 MB (`base`) to ~3 GB (`large-v3`)
  resident through the long gaps between chunks. Recording idles far more than
  it transcribes, and held RAM costs more than a network-free re-read. Pass
  `huske run --no-idle-unload` (or set `whisper_idle_unload = false`) to keep
  the model warm for back-to-back transcription.

## 0.8.1 - 2026-06-10

### Fixed

- Website: the home-page output ledger is now a functional, interactive
  file-tree preview instead of a static block.
- Website: the release history renders Markdown bold correctly instead of
  showing literal `**`.

## 0.8.0 - 2026-06-07

### Added

- LLM distillation into searchable **statements** (opt-in, off by default). A
  local LLM (Ollama; any model tag, default `qwen3.5:0.8b` — the lightest
  portable tier, run non-reasoning) distils each
  transcript into compact, self-contained claims written to a
  `<name>.statements.json` sidecar. With local search enabled, statements are
  embedded into a separate `statements.db`, and `huske mcp` ranks statements
  first — `fetch` returns the matched claim plus the verbatim source transcript
  that grounds it (two-stage retrieval). New `huske distill` backfill, a
  `huske doctor` daemon/model check, and `distill_*` config keys; the send
  transport is dependency-free (loopback HTTP over stdlib). Distillation runs
  off the hot path and degrades gracefully if the daemon is unavailable. See
  `docs/distillation.md` and `docs/adr/0005-llm-distillation.md`.

### Changed

- Screenshots are now smaller on disk by default. The capture interval default
  is `60s` (was `10s`), and each capture is compressed and downscaled in place
  via macOS `sips` (no new dependency, skipped gracefully if `sips` is absent):
  the long edge is clamped to at most `1568px` — Claude's vision target, and it
  never upscales a smaller display — and re-encoded at JPEG quality `60`. New
  `screenshots_max_dimension` / `screenshots_jpeg_quality` config keys and
  `--screenshot-max-dimension` / `--screenshot-quality` flags.
- `keep_audio` now stores compressed audio instead of raw WAV. After a chunk is
  transcribed, its WAV is transcoded to a sibling file and the WAV removed. The
  new `keep_audio_format` config (default `opus`, ~12–20× smaller; `flac` is
  lossless ~2×; `wav` keeps the uncompressed original) drives this via
  `soundfile`/`libsndfile` — no new dependency. Whisper still reads the raw WAV
  first, so transcription is unaffected, and crash recovery is untouched (it
  only handles pre-transcription WAVs).

## 0.7.4 - 2026-06-07

### Added

- Setup guidance for connecting **Claude Desktop and Cowork** to the local
  `huske mcp` server through the `mcp-remote` bridge. Both share one
  `claude_desktop_config.json`, so the same entry exposes huske in Cowork once
  Desktop reloads it. The website home page also gained a quick-start strip that
  surfaces the run-on-login and MCP commands and links to the detailed guides.

### Changed

- Lighter footprint, default-on with no new config. The transcription worker now
  releases the Metal buffer pool after every chunk (not only on idle unload), so
  the per-chunk decode working set is reclaimed during recording gaps even while
  the model stays warm. The ScreenCaptureKit capture stack is now imported
  lazily and loads only when the SCK fallback path actually starts, not on the
  common Core Audio tap path, mic-only mode, or `huske recover`.

### Fixed

- The live UI's "N pending" chunk count was always `0` on macOS: it read
  `multiprocessing.Queue.qsize()`, which raises `NotImplementedError` there. It
  now uses the orchestrator's authoritative pending-chunk count.

## 0.7.3 - 2026-06-03

### Fixed

- The `huske run` startup log now records the running version instead of a
  stale `v0.1.0` placeholder.

### Changed

- The website reads its version from a single source (`website/version.js`),
  and the release tooling now verifies every page matches the released version,
  so the public site no longer drifts to an older version between releases.

## 0.7.2 - 2026-06-03

### Changed

- Website docs page now lives at `/docs/` (clean URL) instead of `/docs.html`.
  In-page nav links no longer expose `index.html` in the URL.

## 0.7.1 - 2026-06-03

### Added

- Idle whisper-model unload (`--idle-unload` / `whisper_idle_unload = true`, off
  by default). The transcription worker drops the model weights after
  `whisper_idle_unload_seconds` of inactivity (default 120 s) and reloads
  lazily on the next chunk, freeing up to ~3 GB of resident RAM during long
  recording gaps. Reloads resolve from a pinned local snapshot directory, so
  they are network-free.
- `--no-menu-bar` (`menu_bar_enabled = false`) now also skips the IPC control
  socket and its accept thread, cutting an additional ~50–80 MB of idle RSS
  when the menu-bar helper is disabled.
- `huske doctor` reports the autostart LaunchAgent state: whether the agent
  is installed, loaded, its running PID, and a pointer to any crash log.
  Informational only; never fails the command; skipped on non-macOS.
- New website docs page covering install, macOS permissions, autostart on
  login, full config reference, and MCP setup for Claude Desktop, Gemini CLI,
  ChatGPT, and other clients.
- `examples/config.toml` now documents every current `RuntimeConfig` key,
  including the new `whisper_idle_unload` and `menu_bar_enabled` footprint
  knobs.

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

### Changed

- `huske index` now runs **low-impact by default**: the backfill lowers its CPU
  priority, shrinks the embed batch, caps the MLX/Metal buffer cache, and
  releases it between files so indexing a long history can't exhaust RAM or pin
  the GPU. Pass `huske index --fast` (or set `index_low_impact = false`) for the
  previous full-speed behavior. New config knobs `embed_batch_size` and
  `index_memory_limit_mb` tune the footprint further; `embed_batch_size` also
  applies to live indexing during `huske run`.

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
