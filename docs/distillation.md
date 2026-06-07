# Transcript distillation (opt-in)

huske can distil each transcript into compact, self-contained **statements**
using a **local** LLM, embed those into a separate search index, and let an MCP
client search the statements first — then drill into the verbatim transcript for
detail. This is *two-stage retrieval*: find the claim, then read what was
actually said.

It is **off by default**, runs **entirely on-device**, and adds **no Python
dependency** (the LLM call is loopback HTTP to a local daemon). The design
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
language):

| Model (`ollama pull …`) | Resident (Q4) | Notes |
| --- | --- | --- |
| `gemma4:e2b` *(default)* | ~2–4 GB | On-device design, 128K context, fast. |
| `qwen3:4b` | ~3 GB | Best extraction quality in the light tier. |
| `llama3.2:3b` | ~2 GB | Lightest; very reliable structured output. |

```bash
ollama pull gemma4:e2b
```

> `huske doctor` (with `distill_enabled` set) checks the daemon is up and the
> model is pulled, and prints the exact `ollama pull …` to run if not.

### 2. Distil your history

```bash
huske distill                  # incremental — only transcripts without a current sidecar
huske distill --model qwen3:4b # override the model for this run
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
distill_model    = "gemma4:e2b"
indexing_enabled = true        # also embed statements live, so `huske mcp` ranks them first
```

`huske run` then distils in a background **thread** and hands each finished
sidecar to the embedding subprocess — both off the hot path. An LLM call never
blocks audio capture; if the daemon is down, recording and passage search
continue and `huske distill` catches up later. Enabling it mid-history does **not**
trigger a surprise whole-corpus backfill — run `huske distill` for that
explicitly.

## Configuration

All keys live in `~/.config/huske/config.toml` (CLI flags on `huske run` /
`huske distill` override per-run):

| Key | Default | Meaning |
| --- | --- | --- |
| `distill_enabled` | `false` | Distil each finished transcript during `huske run`. |
| `distill_backend` | `"ollama"` | LLM daemon backend (only Ollama today). |
| `distill_model` | `"gemma4:e2b"` | Model tag to distil with. Any local tag. |
| `distill_endpoint` | `"http://127.0.0.1:11434"` | Loopback URL of the daemon. |
| `distill_timeout_seconds` | `120.0` | Per-passage LLM call ceiling. |
| `distill_max_statements_per_passage` | `8` | Caps statements per Passage. |
| `distill_low_impact` | `true` | Throttle the `huske distill` backfill (`--fast` to disable). |

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
  stronger model (`distill_model = "qwen3:4b"`) and `huske distill --force`.
