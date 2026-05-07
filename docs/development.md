# Development

huske is a Python CLI/TUI application for macOS audio capture and local
transcription. Most core behavior is testable without real devices; device and
Whisper checks are isolated in integration tests.

## Local setup

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -e ".[dev]"
```

On macOS, grant Screen Recording permission to the Python interpreter before
running real system-audio capture. `huske doctor` validates the local setup.

## Common commands

```bash
huske --help
huske doctor
huske run
huske recover
```

## Checks

Run the current CI baseline before opening a PR:

```bash
pytest tests/unit
pytest tests/integration/test_pipeline_no_whisper.py tests/integration/test_smoke.py
```

Additional local quality checks:

```bash
ruff check .
mypy huske
```

Ruff and Mypy are useful while changing Python code, but they are not required
CI gates yet because the 0.1 branch still needs a dedicated lint/type baseline
cleanup.

Optional integration checks:

```bash
pytest tests/integration/test_system_audio.py
pytest tests/integration/test_real_whisper.py
```

`test_system_audio.py` requires macOS Screen Recording permission.
`test_real_whisper.py` downloads and runs the `tiny` faster-whisper model.

## Project layout

```text
huske/
  capture/       microphone and system-audio capture
  chunker/       WAV chunk rotation
  recovery/      orphaned audio recovery
  transcribe/    worker process and transcript writing
  ui/            Rich live terminal UI
specs/           feature specs, contracts, and planning notes
tests/           unit and integration tests
examples/        example user configuration
```

## Privacy rules for development

- Use synthetic audio in tests and examples.
- Do not commit generated recordings, transcripts, logs, local configs, model
  caches, or screenshots containing private content.
- Redact paths and device names when they reveal private information.
- Keep reproduction cases minimal and deterministic.
