"""Distill transcripts into compact **Statements** (opt-in).

A finalized Transcript is windowed into Passages and each Passage is handed to a
**local** LLM that returns a few self-contained, decontextualized factual
claims — **Statements** (see CONTEXT.md). The Statements are written to a
``<name>.statements.json`` sidecar next to the transcript. Export can use these
derived summaries; the isolated VPS service deliberately builds its own index
from canonical transcript Markdown. See docs/adr/0005-llm-distillation.md.

This package ships in the **base install**. The call is either a private MLX
subprocess or loopback HTTP to Ollama. It is inert unless
``distill_enabled`` is set, so the normal recording path pays nothing.

- :mod:`huske.distill.client`    — the loopback ``POST /api/chat`` call.
- :mod:`huske.distill.distiller` — Passage → Statements (Ollama or a test fake).
- :mod:`huske.distill.sidecar`   — read/write the ``.statements.json`` artifact.
- :mod:`huske.distill.worker`    — a background *thread* that distills off the
  hot path (network I/O releases the GIL, so it can't starve the audio drainer).
- :mod:`huske.distill.runner`    — the ``huske distill`` backfill.
"""

from __future__ import annotations
