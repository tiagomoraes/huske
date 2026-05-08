# Changelog

All notable changes to huske will be documented in this file.

This project uses semantic versioning after the first public release.

## Unreleased

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

### Added

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
