# Transcript distillation (opt-in)

Huske can distil each transcript into compact, self-contained **Statements**
using a local LLM. Distillation is off by default and independent from cloud
sync: canonical transcript Markdown is what Huske publishes to Git and what the
isolated `huske-mcp` service indexes.

Statements are useful for the local `huske export` workflow and for people who
want inspectable summary artifacts beside their transcripts. The design
rationale and historical changes live in
[ADR 0005](adr/0005-llm-distillation.md); ADR 0009 retired the old in-app index
and MCP integration.

## How it works

```text
transcript.md ── local LLM ──► transcript.statements.json
       │
       └── Git sync ──► private repository ──► independent huske-mcp index
```

- Huske windows a finished transcript into time-bounded Passages.
- A local model extracts faithful, one-sentence claims.
- Each Statement records its source time range and audio sources.
- The sidecar is written atomically and can be regenerated at any time.
- `huske sync` deliberately publishes only canonical `.md` transcripts. The
  VPS service derives its own lightweight search index from those files.

## Setup

The default backend is `mlx`, which runs
`mlx-community/Qwen3.5-0.8B-4bit` in a private subprocess and downloads it on
first use. Nothing else needs to be installed.

To use an existing Ollama installation instead:

```toml
distill_backend = "ollama"
distill_model = "qwen3.5:0.8b"
```

Huske can start `ollama serve` and pull a missing model when
`distill_auto_manage = true`; it never installs Ollama.

Distil existing history incrementally:

```bash
huske distill
huske distill --force
huske distill --fast
```

Use the results in day-oriented documents:

```bash
huske export
huske export --statements-only
```

## Keep it automatic

Set this in `~/.config/huske/config.toml`:

```toml
distill_enabled = true
distill_backend = "mlx"
distill_model = "mlx-community/Qwen3.5-0.8B-4bit"
```

`huske run` then distils every completed transcript off the audio hot path. A
model failure never blocks recording or Git sync; `huske distill` catches up
later. Enabling the setting does not trigger a surprise historical backfill.

The live toggle in Huske.app affects the current session only. Persist the
config key to make it the default for future sessions.

## Configuration

| Key | Default | Meaning |
| --- | --- | --- |
| `distill_enabled` | `false` | Distil each finished transcript. |
| `distill_backend` | `"mlx"` | Private MLX subprocess or `"ollama"`. |
| `distill_model` | `"mlx-community/Qwen3.5-0.8B-4bit"` | Local model name. |
| `distill_endpoint` | `"http://127.0.0.1:11434"` | Ollama endpoint. |
| `distill_auto_manage` | `true` | Start Ollama and pull a missing model when possible. |
| `distill_timeout_seconds` | `120.0` | Per-passage deadline. |
| `distill_max_statements_per_passage` | `8` | Statement cap per Passage. |
| `distill_low_impact` | `true` | Throttle historical backfill. |
| `distill_think` | `false` | Enable a reasoning pass when supported. |

`distill_model = "heuristic"` selects the deterministic dependency-free
splitter used by the test suite.

## Footprint and privacy

Distillation is the heaviest optional on-device feature. It is off by default,
runs outside the recording loop, unloads the MLX child after inactivity, and
uses low-impact backfill unless `--fast` is supplied.

The MLX backend stays on the Mac. The Ollama backend sends text to the configured
endpoint, which defaults to loopback; a remote endpoint receives transcript
content and should only be used deliberately.

## Troubleshooting

- If the MLX model cannot load, run `huske doctor` and verify the base
  dependencies are installed.
- If Ollama is unreachable, start the app or `ollama serve`.
- If an Ollama model is missing, run the `ollama pull …` command shown by
  `huske doctor`.
- If a Statement is inaccurate, trust the canonical transcript and re-run with
  a stronger model plus `huske distill --force`.
