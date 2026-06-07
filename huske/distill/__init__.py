"""Distill transcripts into compact, searchable **Statements** (opt-in).

A finalized Transcript is windowed into Passages and each Passage is handed to a
**local** LLM that returns a few self-contained, decontextualized factual
claims — **Statements** (see CONTEXT.md). The Statements are written to a
``<name>.statements.json`` sidecar next to the transcript (the on-disk contract,
mirroring how ``huske.search`` consumes the ``.md``). With local search also
enabled, ``huske.search`` embeds those Statements into a separate statement
store, and ``huske mcp`` searches them first — drilling into the source
transcript on ``fetch``. See docs/adr/0005-llm-distillation.md.

This package ships in the **base install** and is **dependency-free**: the LLM
call is loopback HTTP to a local daemon (Ollama) over stdlib ``urllib`` (mirrors
``huske.sync``). It never imports the heavy ``mlx``/``sqlite-vec`` paths and is
inert unless ``distill_enabled`` is set, so the local-only case pays nothing.

- :mod:`huske.distill.client`    — the loopback ``POST /api/generate`` call.
- :mod:`huske.distill.distiller` — Passage → Statements (Ollama or a test fake).
- :mod:`huske.distill.sidecar`   — read/write the ``.statements.json`` artifact.
- :mod:`huske.distill.worker`    — a background *thread* that distills off the
  hot path (network I/O releases the GIL, so it can't starve the audio drainer).
- :mod:`huske.distill.runner`    — the ``huske distill`` backfill.
"""

from __future__ import annotations
