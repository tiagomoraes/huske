"""Ollama as a post-processing backend (``distill_backend = "ollama"``).

Uses ``/api/chat`` with ``think: false`` (see ``huske.distill.client`` for why
not ``/api/generate``) and a system message for the cleanup rules. Plain-text
replies: the numbered-line protocol in ``huske.distill.correction`` needs no
JSON mode.
"""

from __future__ import annotations

from typing import Any


class OllamaBackend:
    provider = "ollama"
    backend = "ollama"

    def __init__(self, client: Any, model: str, *, think: bool = False) -> None:
        self._client = client
        self.model_id = model
        self._think = think

    def complete(self, instructions: str, prompt: str, *, max_tokens: int) -> str:
        reply = self._client.chat(
            self.model_id,
            prompt,
            system=instructions,
            json_format=False,
            think=self._think,
            options={"temperature": 0.0, "num_predict": int(max_tokens)},
        )
        return str(reply)
