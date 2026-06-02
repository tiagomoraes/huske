---
status: accepted
---

# Embedding runs in an isolated subprocess, not the recording loop

## Context

When `indexing.enabled` is set, huske embeds each finalized transcript into the
passage index *during* `huske run`. The simplest wiring would embed inline in
the main loop as transcripts finalize.

## Decision

Embedding runs in a **dedicated subprocess** fed by `run_loop`, which enqueues
the path of each finalized `.md` transcript. The worker parses runs, windows
them into Passages, embeds, and upserts to `sqlite-vec`. The **same worker
entrypoint** also backs `huske index` (backfill / rebuild).

## Why (the trade-off)

This extends the rule that already isolates the Whisper worker: *heavy,
GIL-holding or Metal-contending compute must not run in the main process or it
starves the ~50 ms audio drainer.* An embedding model is the same class of
load. In-process embedding would reintroduce exactly the starvation the
architecture was built to prevent and would contend with Whisper for Metal.

## Consequences

- One extra subprocess + IPC, consistent with the existing capture/transcribe
  process model. The embed load is bursty (~once per 15-min chunk), off the
  hot path.
- Because the worker consumes the on-disk `.md` (the published transcript
  contract) rather than in-memory segments, the live path and `huske index`
  backfill are the **same code**. The cost is run-start timestamp granularity
  for citations (≈ minute-level), which is sufficient.
