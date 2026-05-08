# Changelog

All notable changes to huske will be documented in this file.

This project uses semantic versioning after the first public release.

## Unreleased

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
