# Transcript distillation (opt-in)

huske can distil each transcript into compact, self-contained **statements**
using a **local** LLM, embed those into a separate search index, and let an MCP
client search the statements first — then drill into the verbatim transcript for
detail. This is *two-stage retrieval*: find the claim, then read what was
actually said.

It is **off by default**, runs **entirely on-device**, and is
**self-contained**: the default backend (`distill_backend = "mlx"`) runs the
model inside huske itself via `mlx-lm` — in an isolated subprocess, on the same
MLX/Metal stack as transcription — and downloads the weights from Hugging Face
on first use (default `mlx-community/Qwen3.5-0.8B-4bit`, ~0.6 GB), exactly like
the Parakeet model. There is nothing to install, start, or keep running.
Setting `distill_backend = "ollama"` instead delegates to a local Ollama
daemon (for models MLX doesn't serve, or an already-running daemon); the known
Qwen tags (`qwen3.5:0.8b` etc.) are auto-mapped to their MLX builds, so a
config written for the old Ollama-only default keeps working. The design
rationale is in [adr/0005-llm-distillation.md](adr/0005-llm-distillation.md);
the domain terms are in [../CONTEXT.md](../CONTEXT.md) (**Statement**).

## How it works

```
transcript.md ──► distil (local LLM) ──► <name>.statements.json   (sidecar, the contract)
                                              │
                                              └► embed (huske[mcp]) ──► statements.db
                                                                          │
huske mcp:  search → ranks statements ──► fetch(statement) → claim + source transcript
```

- A finished transcript is windowed into Passages (the same windows search
  uses); each Passage is sent to the LLM for a few faithful, one-sentence claims.
  The call is **non-reasoning** by default (over Ollama's `/api/chat` with
  `think: false`) — claim extraction needs no chain-of-thought, and skipping it
  is faster; flip `distill_think` on if a model's reasoning helps.
- Claims are written to a `<name>.statements.json` **sidecar** next to the
  transcript. Each statement records the time range of its source Passage, so a
  fetch can ground it back in the transcript by *time* (robust to how either
  index is windowed).
- With local search also enabled, the **same embedder** that indexes Passages
  embeds the statements into a separate `~/huske/index/statements.db`. The
  passage index is never rebuilt or touched.
- `huske mcp` then targets statements by default; `fetch` on a statement returns
  the claim **plus** the verbatim transcript that grounds it.

Statements live in their own store, so you can adopt this incrementally and roll
it back (delete `statements.db` / the sidecars) without affecting passage search.

## Setup

### 1. Run a local model

Install [Ollama](https://ollama.com) and pull a model. Any tag works — pick for
your machine's RAM (all multilingual; huske transcripts are often mixed
language). The default `qwen3.5:0.8b` is the lightest tier and **portable**: it
runs on the Metal/llama.cpp path across the whole Apple-Silicon range, and
Ollama auto-accelerates it on its **MLX** engine where supported.

| Model (`ollama pull …`) | Resident | Notes |
| --- | --- | --- |
| `qwen3.5:0.8b` *(default)* | ~1 GB | Lightest tier; multilingual, 256K context. Runs everywhere. |
| `qwen3.5:0.8b-mlx` | ~1.2 GB | Same model, MLX-format weights — explicit MLX fast path on 32GB+ Macs. |
| `qwen3.5:2b` | ~2.7 GB | More headroom; better extraction on dense passages. |
| `llama3.2:3b` | ~2 GB | Alternative; reliable structured output. |

On Apple Silicon, Ollama's MLX engine (a v0.30 preview) is the fastest path and
is auto-selected at runtime for **MLX-format** models — pull the `-mlx` build of
any tag (e.g. `qwen3.5:2b-mlx`) to opt in. Heavier tiers (`:4b`, `:9b`, …) trade
RAM for quality.

```bash
ollama pull qwen3.5:0.8b
```

> `huske doctor` (with `distill_enabled` set) checks the daemon is up and the
> model is pulled, and prints the exact `ollama pull …` to run if not.

> **You usually don't have to do the two steps above by hand.** When distillation
> turns on (at launch or via the live toggle) huske, by default, starts
> `ollama serve` if the CLI is installed but idle and `ollama pull`s the
> configured model if it's missing — so installing Ollama is typically enough. It
> never installs Ollama itself, and falls back to the same fix-it hint if it
> can't. Opt out with `distill_auto_manage = false` (or `--no-distill-auto-manage`).

### 2. Distil your history

```bash
huske distill                  # incremental — only transcripts without a current sidecar
huske distill --model qwen3.5:4b # override the model for this run
huske distill --force          # re-distil everything
huske distill --fast           # skip the default low-impact CPU throttle
```

This writes the sidecars. It needs only the base install + Ollama.

### 3. Embed the statements for search

```bash
pip install 'huske[mcp]'       # if you haven't already (embeddings + sqlite-vec + MCP SDK)
huske index                    # embeds passages AND any statement sidecars
huske mcp                      # serve search/fetch (statements ranked first)
```

`huske index` embeds both passages and statements in one pass, sharing the one
embedding model. See [the search section of the README](../README.md#search-your-transcripts-from-claude--chatgpt-opt-in)
for connecting Claude / ChatGPT.

### Keep it automatic

Set in `~/.config/huske/config.toml`:

```toml
distill_enabled  = true        # distil each finished transcript during `huske run`
distill_model    = "qwen3.5:0.8b"
indexing_enabled = true        # also embed statements live, so `huske mcp` ranks them first
```

`huske run` then distils in a background **thread** and hands each finished
sidecar to the embedding subprocess — both off the hot path. An LLM call never
blocks audio capture; if the daemon is down, recording and passage search
continue and `huske distill` catches up later. Enabling it mid-history does **not**
trigger a surprise whole-corpus backfill — run `huske distill` for that
explicitly.

You can also flip distillation on or off **without restarting** a session: use
the toggle in Huske.app's Record pane (or its ⌘K palette), or pick **Toggle
distillation** from the macOS menu-bar dropdown. Turning it on first checks that
the model is ready (the same probe as `huske doctor`).

On the default `mlx` backend there is nothing to check — huske downloads the
model on first use. On `distill_backend = "ollama"`, huske makes the daemon
ready for you: it starts the daemon if the `ollama` CLI is installed but idle,
and pulls the configured model if it's missing (progress shown in the events
log), falling back to a fix-it hint only when it can't — for instance when
Ollama isn't installed at all, which huske will never do for you. Set
`distill_auto_manage = false` to keep the old behaviour of reporting the
problem instead of fixing it.

This runtime toggle is session-only; set `distill_enabled = true` above to make
distillation the default for every run.

## Configuration

All keys live in `~/.config/huske/config.toml` (CLI flags on `huske run` /
`huske distill` override per-run):

| Key | Default | Meaning |
| --- | --- | --- |
| `distill_enabled` | `false` | Distil each finished transcript during `huske run`. |
| `distill_backend` | `"ollama"` | LLM daemon backend (only Ollama today). |
| `distill_model` | `"qwen3.5:0.8b"` | Model tag to distil with. Any local tag (e.g. `qwen3.5:0.8b-mlx`). |
| `distill_endpoint` | `"http://127.0.0.1:11434"` | Loopback URL of the daemon. |
| `distill_auto_manage` | `true` | When distillation turns on, start the daemon and pull the model if needed (never installs Ollama). `--no-distill-auto-manage` to opt out. |
| `distill_timeout_seconds` | `120.0` | Per-passage LLM call ceiling. |
| `distill_max_statements_per_passage` | `8` | Caps statements per Passage. |
| `distill_low_impact` | `true` | Throttle the `huske distill` backfill (`--fast` to disable). |
| `distill_think` | `false` | Let a thinking model reason before answering. Off by default — claim extraction needs no reasoning pass, and it's slower. |

Set `distill_model = "heuristic"` to exercise the pipeline with a deterministic,
dependency-free splitter (no daemon) — used by the test suite.

## Footprint

A local LLM is the heaviest thing huske can run, so distillation is built to stay
out of the way:

- **Off by default**, and the base recording path imports none of it.
- **Off the hot path** — a thread feeding a separate daemon; statement embedding
  rides the existing isolated embed subprocess (one model in RAM, not two).
- **The daemon owns the model.** Ollama loads/unloads weights in its own process,
  so the model isn't pinned in huske and can be unloaded when idle.
- The backfill is **low-impact by default** (`huske distill`; `--fast` to opt out).

## Privacy

Distillation sends transcript text to the local LLM daemon you run. By default
that is Ollama on loopback — **on-device**, so nothing leaves your machine.
Pointing `distill_endpoint` at a remote daemon would send transcript text there;
do that only against infrastructure you control. (Note this is separate from the
*answering* step: whichever chat model you connect to `huske mcp` still receives
the statements/transcript it reads, exactly as with passage search.)

## Troubleshooting

- **`huske doctor` says the daemon is unreachable** — start it (`ollama serve`,
  or just run the Ollama app) or fix `distill_endpoint`.
- **`model '…' not pulled`** — run the `ollama pull …` the doctor prints.
- **`huske distill` wrote sidecars but search still returns passages** — run
  `huske index` to embed the statements, then restart `huske mcp`. Search only
  ranks statements once `statements.db` has rows.
- **A statement looks wrong** — open the source transcript (every `fetch`
  returns it) and trust that; statements are a search aid, not the record. Try a
  stronger model (`distill_model = "qwen3.5:4b"`) and `huske distill --force`.
