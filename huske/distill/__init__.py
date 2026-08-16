"""Correct ASR errors in transcripts with a tiny local LLM (opt-in).

A finalized Transcript is handed run-by-run to a **local** LLM that
conservatively fixes typos and obvious mishears. The raw Markdown is
snapshotted to ``<name>.asr.txt``; the canonical ``.md`` is rewritten in
place. A ``<name>.statements.json`` sidecar records the skip-hash and the
polished runs for export. The isolated VPS service indexes the polished
Markdown. See docs/adr/0005-llm-distillation.md.

This package ships in the **base install**. The call is either a private MLX
subprocess or loopback HTTP to Ollama. It is inert unless
``distill_enabled`` is set, so the normal recording path pays nothing.

- :mod:`huske.distill.client`    — the loopback ``POST /api/chat`` call.
- :mod:`huske.distill.distiller` — run → corrected text (Ollama, MLX, or a test fake).
- :mod:`huske.distill.sidecar`   — read/write the ``.statements.json`` artifact.
- :mod:`huske.distill.worker`    — a background *thread* that corrects off the
  hot path (network I/O releases the GIL, so it can't starve the audio drainer).
- :mod:`huske.distill.runner`    — the ``huske distill`` backfill.
"""

from __future__ import annotations
