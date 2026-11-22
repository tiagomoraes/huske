"""Transcript cleanup: an optional LLM pass over finished transcripts.

A finalized Transcript is cleaned up (punctuation, misheard words, the user's
dictionary) by the backend the user chose — Apple Intelligence, the built-in
MLX model, Ollama, an OpenAI-compatible server, or OpenAI / Anthropic /
OpenRouter. The raw Markdown is snapshotted to ``<name>.asr.txt``; the
canonical ``.md`` is rewritten and marked with ``postprocessed_by``. See
docs/adr/0005-llm-distillation.md and
docs/adr/0013-transcript-quality-language-dictionary-llm-cleanup.md.

Inert unless ``distill_enabled`` is set, so the recording path pays nothing.

- :mod:`huske.distill.providers`  — the provider table, placement, consent.
- :mod:`huske.distill.correction` — batching, prompt, reply parsing, fallbacks.
- :mod:`huske.distill.distiller`  — one transcript: snapshot → correct → rewrite.
- :mod:`huske.distill.mlx_backend`, ``ollama_backend``, ``apple``, ``http_llm``
  — the backends (built-in MLX child, Ollama, Apple helper, HTTP APIs).
- :mod:`huske.distill.keychain`   — API keys in the macOS Keychain.
- :mod:`huske.distill.worker`     — the background thread in ``huske run``.
- :mod:`huske.distill.runner`     — the ``huske distill`` backfill.
- :mod:`huske.distill.llm_cli`    — ``huske llm`` (status, models, keys, consent, test).
"""

from __future__ import annotations
