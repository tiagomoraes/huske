# Transcript correction (opt-in)

Huske can polish each finished transcript with a **tiny local LLM**. The job
is conservative ASR correction — typos, missing punctuation, obvious
mishears — not summarisation or statement extraction. Distillation is off by
default and independent from cloud sync: the polished canonical Markdown is
what Huske publishes to Git and what the isolated `huske-mcp` service indexes.

The uncorrected snapshot is kept next to the transcript as `<name>.asr.txt`
so you can always recover the raw ASR. That file is not Markdown, so the
app, `*.md` globs, and Git sync never treat it as a published transcript.

The design rationale and historical statement-extraction path live in
[ADR 0005](adr/0005-llm-distillation.md); ADR 0009 retired the old in-app
index and MCP integration.

## How it works

```text
transcript.md ── copy ──► transcript.asr.txt   (raw ASR, local only)
       │
       └── tiny local LLM, per [HH:MM:SS · source] run
                 │
                 ▼
          transcript.md   (polished; this is what syncs)
                 │
                 └── transcript.statements.json   (skip-hash + polished runs)
```

- Huske snapshots the first-seen `.md` to `.asr.txt`.
- A local model corrects each run independently. Timestamps and sources stay.
- Empty, too-short, or wildly longer replies are rejected; the original run
  is kept.
- The sidecar hashes the **raw** snapshot so a polished `.md` is not
  re-corrected on the next session.
- `huske sync` publishes only canonical `.md` transcripts.

## Setup

The default backend is `mlx`, which runs
`mlx-community/Qwen3.5-0.8B-4bit` in a private subprocess and downloads it
on first use (~0.6 GB). Nothing else needs to be installed.

To use an existing Ollama installation instead:

```toml
distill_backend = "ollama"
distill_model = "qwen3.5:0.8b"
```

`qwen3.5:2b` / `mlx-community/Qwen3.5-2B-4bit` is a bit stronger if the
0.8B model leaves too many errors. `4b` is selectable but heavy for this
job.

Huske can start `ollama serve` and pull a missing model when
`distill_auto_manage = true`; it never installs Ollama.

Correct existing history incrementally:

```bash
huske distill
huske distill --force
huske distill --fast
```

`--force` re-reads `.asr.txt` (the raw snapshot) and rewrites `.md`.

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

`huske run` then corrects every completed transcript off the audio hot
path. A model failure never blocks recording or Git sync; `huske distill`
catches up later. Enabling the setting does not trigger a surprise
historical backfill.

The live toggle in Huske.app affects the current session only. Persist the
config key to make it the default for future sessions.

## Configuration

| Key | Default | Meaning |
| --- | --- | --- |
| `distill_enabled` | `false` | Correct each finished transcript. |
| `distill_backend` | `"mlx"` | Private MLX subprocess or `"ollama"`. |
| `distill_model` | `"mlx-community/Qwen3.5-0.8B-4bit"` | Local model name. |
| `distill_endpoint` | `"http://127.0.0.1:11434"` | Ollama endpoint. |
| `distill_auto_manage` | `true` | Start Ollama and pull a missing model when possible. |
| `distill_timeout_seconds` | `120.0` | Per-run deadline. |
| `distill_max_statements_per_passage` | `8` | Unused by correction; kept for config compatibility. |
| `distill_low_impact` | `true` | Throttle historical backfill. |
| `distill_think` | `false` | Enable a reasoning pass when supported. |

`distill_model = "heuristic"` selects the deterministic identity pass used
by the test suite.

## Footprint and privacy

Correction is the heaviest optional on-device feature, but the default
0.8B 4-bit model is ~0.6 GB and is meant to sit beside ASR, not replace it.
It is off by default, runs outside the recording loop, never overlaps the
ASR model on Metal, and exits the LLM child after inactivity so macOS can
reclaim the heap.

The MLX backend stays on the Mac. The Ollama backend sends text to the
configured endpoint, which defaults to loopback; a remote endpoint receives
transcript content and should only be used deliberately.

## Troubleshooting

- If the MLX model cannot load, run `huske doctor` and verify the base
  dependencies are installed.
- If Ollama is unreachable, start the app or `ollama serve`.
- If an Ollama model is missing, run the `ollama pull …` command shown by
  `huske doctor`.
- If a correction looks wrong, the raw line is in the sibling `.asr.txt`.
  Re-run with a stronger model plus `huske distill --force`, or copy the
  raw text back into the `.md`.
