# Development

huske is a headless Python engine (plus a native macOS app in `macos/`) for
macOS audio capture and local transcription. Most core behavior is testable
without real devices; device and Whisper checks are isolated in integration
tests.

## Local setup

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -e ".[dev]"
```

On macOS, grant the capture permission requested for the Python interpreter
before running real system-audio capture. `huske doctor` validates the effective
backend: Core Audio process tap on macOS 14.4+ or ScreenCaptureKit fallback on
older systems.

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
CI gates yet. Report any baseline failure instead of doing broad cleanup unless
the task is specifically about lint or typing.

Optional integration checks:

```bash
pytest tests/integration/test_system_audio.py
pytest tests/integration/test_real_whisper.py
pytest tests/integration/test_connector_e2e.py
```

`test_system_audio.py` requires macOS Screen Recording permission.
`test_real_whisper.py` downloads and runs the `tiny` mlx-whisper model
(Apple Silicon only — skipped on other platforms).
`test_connector_e2e.py` starts the real `huske mcp` in connector mode on a free
port and drives the whole OAuth flow over HTTP — registration, PKCE, sign-in,
token exchange, refresh rotation — then calls a tool with the issued token. Run
it whenever you touch `huske/mcp/`: it is the only check that catches the
discovery or `/oauth/*` paths colliding with the routes FastMCP mounts, which no
unit test can see. Needs the `mcp` extra installed (`pip install -e ".[dev,mcp]"`),
so it skips on the CI baseline.

## Project layout

```text
huske/
  capture/       microphone and system-audio capture
  chunker/       WAV chunk rotation
  recovery/      orphaned audio recovery
  transcribe/    worker process and transcript writing
docs/            maintainer and contributor documentation
website/         static public website served by GitHub Pages
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
