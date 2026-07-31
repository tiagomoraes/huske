---
status: amended-by-0009
---

# LLM distillation of transcripts into searchable Statements

## Amendment — ADR 0009

The sidecar-producing distillation subsystem remains available for local
summaries and exports. ADR 0009 retired the in-app passage/statement indexes,
embed worker, and `huske mcp` server described below. The isolated VPS service
builds its retrieval index independently from canonical transcript Markdown;
statement sidecars are not part of the Git sync contract.

## Context

Local search retrieves **Passages** — time-windowed slices of raw transcript
text. Conversational speech is verbose, anaphoric, and full of filler, so a
Passage embedding is a noisy retrieval target: the words that matter are diluted
by the words that don't. We want (a) a denser, more searchable unit, and (b) a
compact "memory" of each recording the user (and an agent) can skim.

The technique is **proposition / claim-based retrieval**: distil each transcript
into atomic, self-contained factual **Statements**, embed *those*, search them
first, then drill into the source transcript for depth. Producing Statements
needs a generative LLM — which `multilingual-e5` (an embedding model) is not.

This revisits **ADR 0002**, which considered and *rejected* Ollama as the
embedding backend because it "forces an external daemon users must install and
keep running." That objection stands for a **mandatory** dependency. It does not
stand for an **opt-in** one.

## Decision

Add an opt-in distillation subsystem (`huske.distill`), off by default:

- Each finalized transcript is windowed into Passages (reusing
  `huske.search.windowing`) and each Passage is sent to a **local LLM daemon**
  (Ollama by default, any pulled model) for a few faithful, one-sentence claims.
- The claims are written to a `<name>.statements.json` **sidecar** next to the
  transcript — the on-disk contract, exactly as `huske.search` consumes the
  `.md` (ADR 0003). Each Statement carries its source Passage's **time range**
  as provenance.
- When local search is also enabled, the existing **embed subprocess** embeds
  the Statements (same `e5` embedder, one model in RAM) into a **separate**
  `statements.db` sqlite-vec store. `huske mcp`'s `search` targets Statements by
  default; `fetch` on a statement returns the claim **plus the verbatim source
  transcript** that grounds it (joined by time range).
- Distillation runs in a background **thread** (the LLM is in its own daemon
  process, so from huske it is loopback HTTP — GIL-releasing, like
  `huske.sync`). The transport is stdlib `urllib`: **no new Python dependency**.
- The model is a config string (`distill_model`), so users pick any local model
  (`qwen3.5:0.8b` default — the lightest, portable tier; `qwen3.5:0.8b-mlx` for
  the explicit MLX fast path; heavier `qwen3.5:2b`/`4b`, `llama3.2:3b`, …)
  without code changes.

## Why (the trade-off)

- **Opt-in flips the ADR-0002 calculus.** The daemon is required only for users
  who turn distillation on; the base install and the local-only search path are
  untouched and pull in nothing. The send transport is dependency-free.
- **Graceful degradation.** If the daemon is down or the model isn't pulled,
  recording and passage search continue unaffected; `huske doctor` says how to
  fix it, and `huske distill` / the next session's reconcile catch up.
- **Leans on the daemon's strengths.** Ollama manages model lifecycle —
  including unloading idle weights — in its own process, which suits huske's
  footprint goals better than holding an LLM in-process would.
- **Sidecar = huske's on-disk-contract philosophy (ADR 0003).** Statements are
  inspectable, hand-editable, re-indexable, and replicable, and the slow/optional
  LLM is fully decoupled from Metal embedding and from retrieval.
- **Time-range provenance, not passage uids.** Statements cite *when*, so `fetch`
  grounds them correctly even though the Statement and Passage indexes window
  independently.
- **Separate `statements.db`.** Enabling distillation never forces a rebuild of
  an existing passage index, and the two granularities evolve independently.

## Consequences

- This is the heaviest opt-in compute huske can run. It is off by default, off
  the hot path (a thread feeding a separate daemon), throttled in backfill
  (`huske distill --low-impact`), and relies on the daemon's own model
  unloading. Full two-stage search needs **both** `distill_enabled` (to write
  sidecars) and `indexing_enabled` (to embed them).
- Statement quality depends on the chosen model. Faithfulness is defended by a
  conservative, low-temperature prompt **and** by grounding: `fetch` always
  returns the source transcript, so a consuming agent can verify a claim.
- **Non-reasoning by default.** Extraction is a transformation, not a reasoning
  task, so the call runs with `think: false` over Ollama's `/api/chat` — the
  endpoint that honors the flag (`/api/generate` drops it for thinking models
  like Qwen3.5 and spends the whole token budget on a hidden reasoning pass,
  returning an empty reply). `distill_think` opts reasoning back in.
- The off-device huske server has no LLM, so Statements are produced on the Mac;
  replicating sidecars to the server is a forward-compatible follow-up (the
  sidecar makes it a file copy + the server's existing indexer).

## Update — best-effort daemon auto-management

The "external daemon users must install and keep running" friction (the original
ADR-0002 objection) is softened: when distillation turns on — at launch or via
the app / menu-bar toggle — huske, by default (`distill_auto_manage`), starts
`ollama serve` if the `ollama` CLI is installed but idle, and `ollama pull`s the
configured model if it is missing (streaming progress to the UI). It only ever
runs the local `ollama` CLI — it never installs Ollama — and still degrades to
the same actionable warning when it can't help, so the graceful-degradation and
"no new Python dependency" properties hold. This runs off the hot path (the
callers invoke it from a background thread, like the toggle), keeping the audio
drainer unblocked. It does not change the default-off, opt-in nature of the
subsystem.

**Scope after the `mlx` backend landed (0.11.0).** The embedded backend below
became the default, which makes this a *secondary* path rather than the answer
to the friction — most users never reach it. `ensure_ready` returns the bare
probe unless `distill_backend == "ollama"`, so it is inert for the built-in
backend: starting a daemon nobody asked for, to serve a model that backend does
not use, would be worse than the failure it reports. The probe's `reason` codes
are split accordingly — `no_runtime` (mlx-lm missing, a broken install) is
distinct from `unreachable` / `model_missing`, and only the latter two are
actionable.

## Considered and rejected

- **In-process MLX LLM.** Would ride the stack huske already ships, but holds a
  second large model resident, contends with Whisper/e5 for Metal, and has no
  built-in idle unloading. Ollama's separate, lifecycle-managed process is the
  friendlier default; an `mlx-lm` backend is left as a one-line future addition
  (the `DistillBackend` literal already anticipates it).
- **Whole-transcript distillation (one LLM call).** Fewer calls, but the model
  must self-report time ranges → fuzzy, unreliable provenance. Per-Passage
  distillation gets provenance for free and bounds context.
- **Reusing the `passages` table (a `kind` column / schema bump).** Would force
  every existing index to rebuild and muddle passage-uid math; a sibling store
  is cleaner.
- **A cloud LLM.** Sends transcript text off-device — contrary to huske's
  local-first promise. Distillation is local-only by default; a cloud backend
  would be a separate, loudly-flagged opt-in.
- **Typed statements (decision/action/question tags).** Useful but adds prompt
  complexity and model variance; v1 ships plain claims, leaving typing as a
  follow-up.

## Amendment (v0.11): the built-in MLX backend is now the default

The "in-process MLX LLM" rejection above conflated two things: *in-process*
(GIL-hostile, correctly rejected) and *MLX-based* (fine). With the native macOS
app, requiring users to install and run a separate Ollama daemon became the
single worst step of the distillation UX — so the anticipated `mlx` backend
landed, designed around the original objections:

- **Not in-process.** `huske/distill/mlx_backend.py` runs `mlx-lm` in a private
  **spawn subprocess**; the worker thread blocks on a pipe read (GIL-releasing),
  exactly as it used to block on Ollama's HTTP socket. The drainer invariant
  holds.
- **Idle unloading built in.** The child drops the weights after ~2 min without
  work and reloads from the local HF cache — the same RAM-over-disk trade as
  the transcribe worker (see the footprint policy).
- **Zero setup.** The default model (`mlx-community/Qwen3.5-0.8B-4bit`,
  ~0.6 GB) downloads from Hugging Face on first use, like Parakeet. `mlx-lm`
  ships in the base install on Apple Silicon.

`distill_backend = "ollama"` remains fully supported for daemon users; known
Ollama tags are auto-mapped to their MLX builds so pre-0.11 configs keep
working unchanged.
